//go:build !windows

package main

import (
	"net/http/httptest"
	"testing"
	"time"
)

func newReceiver() *receiver {
	return &receiver{keys: map[uint16]bool{}, buttons: map[uint16]bool{}}
}

func TestEventValid(t *testing.T) {
	cases := []struct {
		name string
		e    event
		want bool
	}{
		{"release", event{Kind: "release"}, true},
		{"enter left edge", event{Kind: "enter", X: 0}, true},
		{"enter right edge", event{Kind: "enter", X: 65535}, true},
		{"enter negative", event{Kind: "enter", X: -1}, false},
		{"enter too wide", event{Kind: "enter", X: 65536}, false},
		{"move in range", event{Kind: "move", X: -10000, Y: 10000}, true},
		{"move too far", event{Kind: "move", X: 10001}, false},
		{"scroll too far", event{Kind: "scroll", Y: -10001}, false},
		{"middle button", event{Kind: "button", Code: 2}, true},
		{"unknown button", event{Kind: "button", Code: 3}, false},
		{"key", event{Kind: "key", Code: 0x1e}, true},
		{"extended key", event{Kind: "key", Code: 0x15b}, true},
		{"zero key", event{Kind: "key", Code: 0}, false},
		{"bare extended prefix", event{Kind: "key", Code: 0x100}, false},
		{"key out of range", event{Kind: "key", Code: 0x180}, false},
		{"unknown kind", event{Kind: "shell"}, false},
	}
	for _, c := range cases {
		if got := c.e.valid(); got != c.want {
			t.Errorf("%s: valid() = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestValidEvents(t *testing.T) {
	if validEvents(nil) {
		t.Error("nil batch must be rejected")
	}
	if !validEvents([]event{}) {
		t.Error("empty batch is a keep-alive and must be accepted")
	}
	if validEvents(make([]event, 257)) {
		t.Error("batch over 256 events must be rejected")
	}
	if validEvents([]event{{Kind: "release"}, {Kind: "bogus"}}) {
		t.Error("one invalid event must reject the batch")
	}
}

func TestApplyTracksAndReleasesHeldInput(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	_, err := r.apply([]event{
		{Kind: "key", Code: 0x1d, Down: true},
		{Kind: "key", Code: 0x2e, Down: true},
		{Kind: "key", Code: 0x2e},
		{Kind: "button", Code: 0, Down: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !r.keys[0x1d] || r.keys[0x2e] || !r.buttons[0] {
		t.Fatalf("held state wrong: keys=%v buttons=%v", r.keys, r.buttons)
	}
	before := len(sentEvents())
	if _, err := r.apply([]event{{Kind: "release"}}); err != nil {
		t.Fatal(err)
	}
	released := sentEvents()[before:]
	want := map[event]bool{{Kind: "key", Code: 0x1d}: true, {Kind: "button", Code: 0}: true}
	if len(released) != len(want) {
		t.Fatalf("release sent %v, want key-up for Ctrl and button-up", released)
	}
	for _, e := range released {
		if !want[e] {
			t.Errorf("unexpected release event %+v", e)
		}
	}
	if len(r.keys) != 0 || len(r.buttons) != 0 {
		t.Errorf("held input left after release: keys=%v buttons=%v", r.keys, r.buttons)
	}
}

func TestReleaseKeepsKeysWhoseKeyUpFailed(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	r.keys[0x1d] = true
	r.keys[0x2a] = true
	fake.mu.Lock()
	fake.failKey = 0x2a
	fake.mu.Unlock()
	r.release()
	if r.keys[0x1d] || !r.keys[0x2a] {
		t.Fatalf("keys=%v, want only the failed key 0x2a kept for retry", r.keys)
	}
}

func TestApplyPropagatesSendError(t *testing.T) {
	resetFake(t)
	fake.mu.Lock()
	fake.err = errFake
	fake.mu.Unlock()
	if _, err := newReceiver().apply([]event{{Kind: "move", X: 1}}); err == nil {
		t.Fatal("send failure must be returned to the caller")
	}
}

// enterSettled enters Windows and backdates the entry past the 200 ms guard.
func enterSettled(t *testing.T, r *receiver) {
	t.Helper()
	if _, err := r.apply([]event{{Kind: "enter", X: 32768}}); err != nil {
		t.Fatal(err)
	}
	r.enteredAt = time.Now().Add(-time.Second)
}

func TestBottomPushReturnsControl(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	enterSettled(t, r)
	r.keys[0x1d] = true
	setBottom(true)
	if returned, _ := r.apply([]event{{Kind: "move", Y: 25}}); returned {
		t.Fatal("25 px push must not return (Start menu / taskbar protection)")
	}
	if returned, _ := r.apply([]event{{Kind: "move", Y: 30}}); returned {
		t.Fatal("55 px push must not return yet")
	}
	returned, err := r.apply([]event{{Kind: "move", Y: 5}})
	if err != nil || !returned {
		t.Fatalf("60 px push at bottom: returned=%v err=%v, want true", returned, err)
	}
	if len(r.keys) != 0 {
		t.Error("returning control must release held keys")
	}
}

func TestBottomPushIgnoredRightAfterEnter(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	if _, err := r.apply([]event{{Kind: "enter"}}); err != nil {
		t.Fatal(err)
	}
	setBottom(true)
	if returned, _ := r.apply([]event{{Kind: "move", Y: 100}}); returned {
		t.Fatal("push within 200 ms of entering must not bounce control back")
	}
}

func TestBottomPushResetByUpwardOrHorizontalMove(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	enterSettled(t, r)
	setBottom(true)
	r.apply([]event{{Kind: "move", Y: 40}})
	r.apply([]event{{Kind: "move", Y: -1}})
	if returned, _ := r.apply([]event{{Kind: "move", Y: 40}}); returned {
		t.Fatal("an upward move must reset the accumulated push")
	}
	r.apply([]event{{Kind: "move", X: 20, Y: 5}})
	if returned, _ := r.apply([]event{{Kind: "move", Y: 40}}); returned {
		t.Fatal("horizontal motion along the taskbar must reset the accumulated push")
	}
}

func TestBottomPushIgnoredWhileDragging(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	enterSettled(t, r)
	setBottom(true)
	r.apply([]event{{Kind: "button", Code: 0, Down: true}})
	if returned, _ := r.apply([]event{{Kind: "move", Y: 100}}); returned {
		t.Fatal("dragging at the bottom edge must not return control")
	}
}

func TestBottomPushExpiresAfterPause(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	enterSettled(t, r)
	setBottom(true)
	r.apply([]event{{Kind: "move", Y: 40}})
	r.lastBottomPush = time.Now().Add(-300 * time.Millisecond)
	if returned, _ := r.apply([]event{{Kind: "move", Y: 30}}); returned {
		t.Fatal("stale downward push after a pause must not accumulate")
	}
}

func TestBottomPushOnlyAtBottomEdge(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	enterSettled(t, r)
	if returned, _ := r.apply([]event{{Kind: "move", Y: 100}}); returned {
		t.Fatal("moving down away from the bottom edge must not return control")
	}
}

func TestReturnStopsProcessingBatch(t *testing.T) {
	resetFake(t)
	r := newReceiver()
	enterSettled(t, r)
	setBottom(true)
	before := len(sentEvents())
	returned, _ := r.apply([]event{{Kind: "move", Y: 60}, {Kind: "key", Code: 0x1e, Down: true}})
	if !returned {
		t.Fatal("expected return")
	}
	for _, e := range sentEvents()[before:] {
		if e.Kind == "key" && e.Down {
			t.Fatal("events after the return point must not reach Windows")
		}
	}
}

func TestAuthorized(t *testing.T) {
	token := "00112233445566778899aabbccddeeff"
	cases := map[string]bool{
		"Bearer " + token:       true,
		"Bearer " + token + "0": false,
		"bearer " + token:       false,
		token:                   false,
		"":                      false,
		"Bearer " + token[:31]:  false,
	}
	for header, want := range cases {
		req := httptest.NewRequest("GET", "/", nil)
		if header != "" {
			req.Header.Set("Authorization", header)
		}
		if got := authorized(req, token); got != want {
			t.Errorf("authorized(%q) = %v, want %v", header, got, want)
		}
	}
}
