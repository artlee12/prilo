//go:build !windows

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type streamHarness struct {
	t       *testing.T
	r       *receiver
	server  *httptest.Server
	control *sync.Mutex
}

func newStream(t *testing.T) *streamHarness {
	t.Helper()
	resetFake(t)
	h := &streamHarness{t: t, r: newReceiver(), control: &sync.Mutex{}}
	h.server = httptest.NewServer(inputStream(h.r, h.control, testToken))
	t.Cleanup(h.server.Close)
	return h
}

func (h *streamHarness) dial(token string) (*websocket.Conn, *http.Response, error) {
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	header.Set("X-Prilo-Features", "sync")
	return websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(h.server.URL, "http"), header)
}

func (h *streamHarness) connect() *websocket.Conn {
	h.t.Helper()
	ws, _, err := h.dial(testToken)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { ws.Close() })
	if got := h.read(ws); got.Type != "ready" {
		h.t.Fatalf("first message %+v, want ready", got)
	}
	return ws
}

func (h *streamHarness) read(ws *websocket.Conn) streamMessage {
	h.t.Helper()
	var message streamMessage
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if err := ws.ReadJSON(&message); err != nil {
		h.t.Fatalf("read: %v", err)
	}
	return message
}

func (h *streamHarness) send(ws *websocket.Conn, frame inputFrame) {
	h.t.Helper()
	if err := ws.WriteJSON(frame); err != nil {
		h.t.Fatal(err)
	}
}

// waitFor polls until cond holds; the handler applies frames on its own goroutine.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (h *streamHarness) held(code uint16) bool {
	h.r.mu.Lock()
	defer h.r.mu.Unlock()
	return h.r.keys[code]
}

func TestStreamRequiresToken(t *testing.T) {
	h := newStream(t)
	_, resp, err := h.dial("ffffffffffffffffffffffffffffffff")
	if err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token: err=%v resp=%v, want 401", err, resp)
	}
}

func TestStreamAllowsOneController(t *testing.T) {
	h := newStream(t)
	h.connect()
	_, resp, err := h.dial(testToken)
	if err == nil || resp == nil || resp.StatusCode != http.StatusConflict {
		t.Fatalf("second controller: err=%v resp=%v, want 409", err, resp)
	}
}

func TestStreamEnterAndInput(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 7, Events: []event{{Kind: "enter", X: 100}}})
	if got := h.read(ws); got.Type != "entered" || got.Capture != 7 {
		t.Fatalf("got %+v, want entered for capture 7", got)
	}
	h.send(ws, inputFrame{Capture: 7, Events: []event{{Kind: "key", Code: 0x1e, Down: true}}})
	waitFor(t, "key held", func() bool { return h.held(0x1e) })
}

func TestStreamIgnoresStaleCapture(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 2, Events: []event{{Kind: "enter"}}})
	h.read(ws)
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "key", Code: 0x10, Down: true}}})
	h.send(ws, inputFrame{Capture: 0, Events: []event{{Kind: "key", Code: 0x11, Down: true}}})
	h.send(ws, inputFrame{Capture: 2, Events: []event{{Kind: "key", Code: 0x12, Down: true}}})
	waitFor(t, "current capture applied", func() bool { return h.held(0x12) })
	if h.held(0x10) || h.held(0x11) {
		t.Fatal("frames from another capture must be dropped")
	}
}

func TestStreamReportsReturn(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 3, Events: []event{{Kind: "enter"}}})
	h.read(ws)
	h.r.mu.Lock()
	h.r.enteredAt = time.Now().Add(-time.Second)
	h.r.mu.Unlock()
	setBottom(true)
	h.send(ws, inputFrame{Capture: 3, Events: []event{{Kind: "move", Y: 60}}})
	if got := h.read(ws); got.Type != "returned" || got.Capture != 3 {
		t.Fatalf("got %+v, want returned for capture 3", got)
	}
}

func TestStreamRejectsInvalidFrame(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "key", Code: 0x500}}})
	if got := h.read(ws); got.Type != "invalid" {
		t.Fatalf("got %+v, want invalid", got)
	}
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := ws.ReadMessage(); err == nil {
		t.Fatal("connection must close after an invalid frame")
	}
}

func TestStreamReportsInputFailure(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "enter"}}})
	h.read(ws)
	fake.mu.Lock()
	fake.err = errFake
	fake.mu.Unlock()
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "move", X: 1}}})
	if got := h.read(ws); got.Type != "inputUnavailable" {
		t.Fatalf("got %+v, want inputUnavailable", got)
	}
}

func TestStreamDisconnectReleasesKeys(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 5, Events: []event{{Kind: "enter"}, {Kind: "key", Code: 0x1d, Down: true}}})
	h.read(ws)
	waitFor(t, "ctrl held", func() bool { return h.held(0x1d) })
	ws.Close()
	waitFor(t, "ctrl released after disconnect", func() bool { return !h.held(0x1d) })
	// The controller slot must be free again.
	waitFor(t, "control unlocked", func() bool {
		if h.control.TryLock() {
			h.control.Unlock()
			return true
		}
		return false
	})
}

func TestStoppingHostedStreamClosesSocketAndReleasesInput(t *testing.T) {
	resetFake(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := &streamHarness{t: t, r: newReceiver(), control: &sync.Mutex{}}
	h.server = httptest.NewServer(inputStreamContext(ctx, h.r, h.control, testToken))
	defer h.server.Close()
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "enter"}, {Kind: "key", Code: 30, Down: true}}})
	if got := h.read(ws); got.Type != "entered" || !h.held(30) {
		t.Fatalf("expected captured key, got %+v", got)
	}
	cancel()
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := ws.ReadMessage(); err == nil {
		t.Fatal("hosted stream did not close")
	}
	waitFor(t, "released key", func() bool { return !h.held(30) })
}

func TestStreamClipboardMacToWindows(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Type: "clipboard", Clipboard: "line1\nline2"})
	waitFor(t, "clipboard written on Windows", func() bool {
		return fakeClipboard() == "line1\r\nline2"
	})
	// Applying remote clipboard must not echo back to Mac.
	_ = ws.SetReadDeadline(time.Now().Add(350 * time.Millisecond))
	var extra streamMessage
	if err := ws.ReadJSON(&extra); err == nil {
		t.Fatalf("unexpected echo message: %+v", extra)
	}
}

func TestStreamClipboardWindowsToMac(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	setFakeClipboard("hello\r\nworld")
	got := h.read(ws)
	if got.Type != "clipboard" || got.Text != "hello\nworld" {
		t.Fatalf("got %+v, want clipboard with normalized LF text", got)
	}
}

func TestStreamClipboardIgnoresOversizedPayload(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	oversized := strings.Repeat("a", maxClipboardBytes+1)
	h.send(ws, inputFrame{Type: "clipboard", Clipboard: oversized})
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "enter"}}})
	if got := h.read(ws); got.Type != "entered" {
		t.Fatalf("got %+v, want entered", got)
	}
	if fakeClipboard() != "" {
		t.Fatal("oversized clipboard must be ignored")
	}
}

func samplePNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, 2, 2))
	img.SetNRGBA(0, 0, color.NRGBA{R: 255, G: 0, B: 0, A: 255})
	img.SetNRGBA(1, 0, color.NRGBA{R: 0, G: 255, B: 0, A: 255})
	img.SetNRGBA(0, 1, color.NRGBA{R: 0, G: 0, B: 255, A: 255})
	img.SetNRGBA(1, 1, color.NRGBA{R: 0, G: 0, B: 0, A: 0})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestClipboardPNGAndDIBRoundTrip(t *testing.T) {
	pngData := samplePNG(t)
	dib, err := pngToDIB(pngData)
	if err != nil {
		t.Fatalf("pngToDIB: %v", err)
	}
	outPNG, err := dibToPNG(dib)
	if err != nil {
		t.Fatalf("dibToPNG: %v", err)
	}
	decoded, err := png.Decode(bytes.NewReader(outPNG))
	if err != nil {
		t.Fatalf("png.Decode: %v", err)
	}
	// Bottom-right transparent pixel was composited over white in DIB.
	r, g, b, _ := decoded.At(1, 1).RGBA()
	if r>>8 != 255 || g>>8 != 255 || b>>8 != 255 {
		t.Fatalf("transparent pixel composite = (%d,%d,%d), want white", r>>8, g>>8, b>>8)
	}
	// All-zero alpha 32-bit DIB (like Windows PrintScreen) must decode as opaque.
	dibZeroAlpha := append([]byte(nil), dib...)
	for i := 40; i+3 < len(dibZeroAlpha); i += 4 {
		dibZeroAlpha[i+3] = 0
	}
	opaquePNG, err := dibToPNG(dibZeroAlpha)
	if err != nil {
		t.Fatalf("dibToPNG zero alpha: %v", err)
	}
	opaqueImg, err := png.Decode(bytes.NewReader(opaquePNG))
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, a := opaqueImg.At(0, 0).RGBA()
	if a>>8 != 255 {
		t.Fatalf("all-zero alpha DIB got alpha=%d, want 255", a>>8)
	}

	// 24-bit bottom-up DIB with odd width (padding check).
	dib24 := make([]byte, 40+4)
	binary.LittleEndian.PutUint32(dib24[0:4], 40)
	binary.LittleEndian.PutUint32(dib24[4:8], 1)
	binary.LittleEndian.PutUint32(dib24[8:12], 1)
	binary.LittleEndian.PutUint16(dib24[12:14], 1)
	binary.LittleEndian.PutUint16(dib24[14:16], 24)
	dib24[40], dib24[41], dib24[42] = 10, 20, 30
	png24, err := dibToPNG(dib24)
	if err != nil {
		t.Fatalf("dibToPNG 24-bit: %v", err)
	}
	img24, err := png.Decode(bytes.NewReader(png24))
	if err != nil {
		t.Fatal(err)
	}
	r24, g24, b24, _ := img24.At(0, 0).RGBA()
	if r24>>8 != 30 || g24>>8 != 20 || b24>>8 != 10 {
		t.Fatalf("24-bit pixel = (%d,%d,%d), want (30,20,10)", r24>>8, g24>>8, b24>>8)
	}
}

func TestStreamClipboardImageSyncAndNoEcho(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	pngData := samplePNG(t)
	h.send(ws, inputFrame{Type: "clipboardImage", Image: base64.StdEncoding.EncodeToString(pngData)})
	waitFor(t, "image clipboard written on Windows", func() bool {
		return bytes.Equal(fakeClipboardImage(), pngData)
	})
	_ = ws.SetReadDeadline(time.Now().Add(350 * time.Millisecond))
	var extra streamMessage
	if err := ws.ReadJSON(&extra); err == nil {
		t.Fatalf("unexpected echo message: %+v", extra)
	}
}

func TestStreamClipboardImageWindowsToMac(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	pngData := samplePNG(t)
	setFakeClipboardImage(pngData)
	got := h.read(ws)
	if got.Type != "clipboardImage" {
		t.Fatalf("got %+v, want clipboardImage", got)
	}
	decoded, err := base64.StdEncoding.DecodeString(got.Image)
	if err != nil || !bytes.Equal(decoded, pngData) {
		t.Fatalf("decoded image mismatch err=%v", err)
	}
}

func TestStreamAwakeFramePulsesKeepAwake(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	on := true
	h.send(ws, inputFrame{Type: "awake", Awake: &on})
	waitFor(t, "keep-awake pulse", func() bool {
		return awakePulses() >= 1
	})
}

func TestShortcutCombos(t *testing.T) {
	expectedCounts := map[string]int{
		"desktopNext":    3,
		"desktopPrev":    3,
		"taskView":       2,
		"showDesktop":    2,
		"switchAppNext":  2,
		"switchAppPrev":  3,
		"browserForward": 2,
		"browserBack":    2,
		"snip":           1,
	}
	for action, wantLen := range expectedCounts {
		if !validShortcutAction(action) {
			t.Fatalf("%s should be valid", action)
		}
		keys, ok := shortcutCombo(action)
		if !ok || len(keys) != wantLen {
			t.Fatalf("%s combo ok=%v len=%d, want %d", action, ok, len(keys), wantLen)
		}
	}
	if !validShortcutAction("zoomIn") || !validShortcutAction("zoomOut") {
		t.Fatal("zoomIn and zoomOut should be valid actions")
	}
	if validShortcutAction("unknown") {
		t.Fatal("unknown shortcut should be invalid")
	}
	next, _ := shortcutCombo("desktopNext")
	if !next[1].extended || next[1].vk != 0x5B || !next[2].extended || next[2].vk != 0x27 {
		t.Fatalf("desktopNext must mark Win and Right arrow as extended: %+v", next)
	}
	prev, _ := shortcutCombo("desktopPrev")
	if !prev[1].extended || prev[1].vk != 0x5B || !prev[2].extended || prev[2].vk != 0x25 {
		t.Fatalf("desktopPrev must mark Win and Left arrow as extended: %+v", prev)
	}
	snip, _ := shortcutCombo("snip")
	if len(snip) != 1 || !snip[0].extended || snip[0].vk != 0x2C || snip[0].scan != 0x37 {
		t.Fatalf("snip combo mismatch: %+v", snip)
	}
}

func TestStreamShortcut(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Type: "shortcut", Capture: 1, Action: "desktopNext"})
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "enter", X: 100}}})
	if got := h.read(ws); got.Type != "entered" || got.Capture != 4 {
		t.Fatalf("got %+v, want entered for capture 4", got)
	}
	h.send(ws, inputFrame{Type: "shortcut", Capture: 3, Action: "desktopPrev"})
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "unknown"})
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "key", Code: 0x2a, Down: true}}})
	waitFor(t, "shift held before snip", func() bool { return h.held(0x2a) })
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "snip"})
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "desktopNext"})
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "zoomIn"})
	waitFor(t, "three valid shortcuts", func() bool {
		return len(sentShortcuts()) == 3
	})
	got := sentShortcuts()
	if got[0] != "snip" || got[1] != "desktopNext" || got[2] != "zoomIn" {
		t.Fatalf("shortcuts = %v, want [snip desktopNext zoomIn]", got)
	}
	if h.held(0x2a) {
		t.Fatal("snip must release held modifiers first")
	}
	// Stream must still accept events after invalid/stale shortcut frames.
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "key", Code: 0x1e, Down: true}}})
	waitFor(t, "key held after shortcut", func() bool { return h.held(0x1e) })
}

func TestDeviceInfoAdvertisesCapabilities(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/device", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()
	deviceInfo(testToken)(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var info map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info["stream"] != "1" || info["shortcut"] != "1" || info["files"] != "1" || info["sync"] != "1" {
		t.Fatalf("info = %+v, want stream=1, shortcut=1, files=1", info)
	}
}

func TestSanitizeFilenameAndUniquePath(t *testing.T) {
	cases := map[string]string{
		"../../etc/passwd":         "passwd",
		`C:\Users\me\photo:1?.png`: "photo_1_.png",
		"CON":                      "_CON",
		"nul.txt":                  "_nul.txt",
		"..":                       "file",
		"":                         "file",
		"%D0%9E%D1%82%D1%87%D1%91%D1%82%202026.pdf": "Отчёт 2026.pdf",
	}
	for raw, want := range cases {
		if got := sanitizeFilename(raw); got != want {
			t.Fatalf("sanitizeFilename(%q) = %q, want %q", raw, got, want)
		}
	}
	dir := t.TempDir()
	p1, n1, err := uniqueFilePath(dir, "doc.txt")
	if err != nil || n1 != "doc.txt" || p1 != filepath.Join(dir, "doc.txt") {
		t.Fatalf("first uniqueFilePath = (%q, %q, %v)", p1, n1, err)
	}
	if err := os.WriteFile(p1, []byte("1"), 0o600); err != nil {
		t.Fatal(err)
	}
	p2, n2, err := uniqueFilePath(dir, "doc.txt")
	if err != nil || n2 != "doc (2).txt" || p2 != filepath.Join(dir, "doc (2).txt") {
		t.Fatalf("second uniqueFilePath = (%q, %q, %v)", p2, n2, err)
	}
}

func TestFileUploadDeduplicatesSetsClipboardAndDoesNotEcho(t *testing.T) {
	resetFake(t)
	dir := t.TempDir()
	clip := newClipboardBridge()
	store := newFileStore()
	ctrl := &sync.Mutex{}
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", inputStreamWithBridge(context.Background(), newReceiver(), ctrl, testToken, clip, store))
	mux.HandleFunc("/file", handleFileUpload(testToken, clip, store, func(string) (string, error) {
		return dir, nil
	}))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/stream", http.Header{
		"Authorization":    []string{"Bearer " + testToken},
		"X-Prilo-Features": []string{"sync"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var ready streamMessage
	if err := ws.ReadJSON(&ready); err != nil || ready.Type != "ready" {
		t.Fatalf("ready = %+v, err=%v", ready, err)
	}

	upload := func(body, filename string) int {
		req, err := http.NewRequest(http.MethodPost, srv.URL+"/file", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+testToken)
		req.Header.Set("X-Prilo-Filename", filename)
		req.Header.Set("X-Prilo-Destination", "downloads")
		req.Header.Set("X-Prilo-Batch", "batch-1")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		_, _ = io.ReadAll(resp.Body)
		return resp.StatusCode
	}

	// Unauthenticated upload must fail.
	unauthReq, _ := http.NewRequest(http.MethodPost, srv.URL+"/file", strings.NewReader("x"))
	if resp, err := http.DefaultClient.Do(unauthReq); err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauth status = %v err=%v, want 401", resp.StatusCode, err)
	}

	if code := upload("hello", "notes.txt"); code != http.StatusOK {
		t.Fatalf("first upload = %d, want 200", code)
	}
	if code := upload("world", "notes.txt"); code != http.StatusOK {
		t.Fatalf("second upload = %d, want 200", code)
	}
	data1, err := os.ReadFile(filepath.Join(dir, "notes.txt"))
	if err != nil || string(data1) != "hello" {
		t.Fatalf("notes.txt = %q, %v", data1, err)
	}
	data2, err := os.ReadFile(filepath.Join(dir, "notes (2).txt"))
	if err != nil || string(data2) != "world" {
		t.Fatalf("notes (2).txt = %q, %v", data2, err)
	}
	gotFiles := fakeClipboardFiles()
	if len(gotFiles) != 2 {
		t.Fatalf("clipboard files = %v, want 2 files in batch", gotFiles)
	}

	// Uploaded files placed in Windows clipboard must NOT echo back to Mac as fileOffer.
	_ = ws.SetReadDeadline(time.Now().Add(350 * time.Millisecond))
	var echo streamMessage
	if err := ws.ReadJSON(&echo); err == nil {
		t.Fatalf("unexpected fileOffer echo: %+v", echo)
	}
}

func TestStreamClipboardFileOfferAndDownload(t *testing.T) {
	resetFake(t)
	srcDir := t.TempDir()
	samplePath := filepath.Join(srcDir, "report.pdf")
	if err := os.WriteFile(samplePath, []byte("pdf-bytes-123"), 0o600); err != nil {
		t.Fatal(err)
	}

	clip := newClipboardBridge()
	store := newFileStore()
	ctrl := &sync.Mutex{}
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", inputStreamWithBridge(context.Background(), newReceiver(), ctrl, testToken, clip, store))
	mux.HandleFunc("/file/download", handleFileDownload(testToken, store))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/stream", http.Header{
		"Authorization":    []string{"Bearer " + testToken},
		"X-Prilo-Features": []string{"sync"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var ready streamMessage
	if err := ws.ReadJSON(&ready); err != nil || ready.Type != "ready" {
		t.Fatalf("ready = %+v, err=%v", ready, err)
	}

	setFakeClipboardFiles([]string{samplePath})
	var msg streamMessage
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if err := ws.ReadJSON(&msg); err != nil {
		t.Fatal(err)
	}
	if msg.Type != "fileOffer" || len(msg.Files) != 1 || msg.Files[0].Name != "report.pdf" || msg.Files[0].Size != 13 {
		t.Fatalf("offer = %+v, want single report.pdf offer", msg)
	}

	dlReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/file/download?id="+msg.Files[0].ID, nil)
	dlReq.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(dlReq)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("download status = %d, want 200", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil || string(body) != "pdf-bytes-123" {
		t.Fatalf("downloaded body = %q, %v", body, err)
	}
}

func TestStreamDropBarSendsFileDrop(t *testing.T) {
	resetFake(t)
	srcDir := t.TempDir()
	samplePath := filepath.Join(srcDir, "dropped.txt")
	if err := os.WriteFile(samplePath, []byte("from-windows-drop"), 0o600); err != nil {
		t.Fatal(err)
	}

	clip := newClipboardBridge()
	store := newFileStore()
	ctrl := &sync.Mutex{}
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", inputStreamWithBridge(context.Background(), newReceiver(), ctrl, testToken, clip, store))
	mux.HandleFunc("/file/download", handleFileDownload(testToken, store))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/stream", http.Header{
		"Authorization":    []string{"Bearer " + testToken},
		"X-Prilo-Features": []string{"sync"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var ready streamMessage
	if err := ws.ReadJSON(&ready); err != nil || ready.Type != "ready" {
		t.Fatalf("ready = %+v, err=%v", ready, err)
	}

	triggerFakeDrop([]string{samplePath})
	var msg streamMessage
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if err := ws.ReadJSON(&msg); err != nil {
		t.Fatal(err)
	}
	if msg.Type != "fileDrop" || len(msg.Files) != 1 || msg.Files[0].Name != "dropped.txt" {
		t.Fatalf("drop message = %+v, want fileDrop for dropped.txt", msg)
	}

	dlReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/file/download?id="+msg.Files[0].ID, nil)
	dlReq.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(dlReq)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil || string(body) != "from-windows-drop" {
		t.Fatalf("downloaded = %q, %v", body, err)
	}
}

func TestLayoutCodeFromHKLAndStreamPush(t *testing.T) {
	if got := layoutCodeFromHKL(0x04190419); got != "RU" {
		t.Fatalf("layout(0x04190419) = %q, want RU", got)
	}
	if got := layoutCodeFromHKL(0x04090409); got != "EN" {
		t.Fatalf("layout(0x04090409) = %q, want EN", got)
	}
	if got := layoutCodeFromHKL(0); got != "" {
		t.Fatalf("layout(0) = %q, want empty", got)
	}

	h := newStream(t)
	setFakeLayout("EN")
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 7, Events: []event{{Kind: "enter", X: 100}}})
	if got := h.read(ws); got.Type != "entered" || got.Capture != 7 {
		t.Fatalf("entered = %+v", got)
	}
	if got := h.read(ws); got.Type != "layout" || got.Capture != 7 || got.Text != "EN" {
		t.Fatalf("initial layout = %+v, want EN", got)
	}
	setFakeLayout("RU")
	if got := h.read(ws); got.Type != "layout" || got.Capture != 7 || got.Text != "RU" {
		t.Fatalf("changed layout = %+v, want RU", got)
	}
}

func TestFileStoreRetainsEntriesAndGzipDownload(t *testing.T) {
	resetFake(t)
	dir := t.TempDir()
	txtPath := filepath.Join(dir, "big.txt")
	zipPath := filepath.Join(dir, "archive.zip")
	txtData := bytes.Repeat([]byte("hello prilo "), 400) // ~6 KB compressible
	zipData := bytes.Repeat([]byte("PK\x03\x04"), 1500)
	if err := os.WriteFile(txtPath, txtData, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(zipPath, zipData, 0o600); err != nil {
		t.Fatal(err)
	}

	store := newFileStore()
	first := store.register([]string{txtPath})
	second := store.register([]string{zipPath})
	if len(first) != 1 || len(second) != 1 {
		t.Fatalf("registered = %d, %d", len(first), len(second))
	}
	// Earlier registered file must still be downloadable after subsequent register() calls.
	if _, ok := store.lookup(first[0].ID); !ok {
		t.Fatal("first file evicted prematurely by second register()")
	}
	// Unchanged file must reuse the same ID.
	again := store.register([]string{txtPath})
	if len(again) != 1 || again[0].ID != first[0].ID {
		t.Fatalf("unchanged file ID = %q, want %q", again[0].ID, first[0].ID)
	}

	srv := httptest.NewServer(handleFileDownload(testToken, store))
	defer srv.Close()

	// Compressible .txt with Accept-Encoding: gzip should return Content-Encoding: gzip (http.Client auto-decompresses).
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/file/download?id="+first[0].ID, nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.Header.Get("X-Prilo-Raw-Size") != fmt.Sprintf("%d", len(txtData)) {
		t.Fatalf("X-Prilo-Raw-Size = %q", resp.Header.Get("X-Prilo-Raw-Size"))
	}
	gotTxt, err := io.ReadAll(resp.Body)
	if err != nil || !bytes.Equal(gotTxt, txtData) {
		t.Fatalf("txt download mismatch len=%d err=%v", len(gotTxt), err)
	}

	// Pre-compressed .zip must skip gzip.
	reqZip, _ := http.NewRequest(http.MethodGet, srv.URL+"/file/download?id="+second[0].ID, nil)
	reqZip.Header.Set("Authorization", "Bearer "+testToken)
	reqZip.Header.Set("Accept-Encoding", "gzip")
	respZip, err := (&http.Client{Transport: &http.Transport{DisableCompression: true}}).Do(reqZip)
	if err != nil {
		t.Fatal(err)
	}
	defer respZip.Body.Close()
	if respZip.Header.Get("Content-Encoding") != "" {
		t.Fatalf("zip should not be gzipped, got Content-Encoding=%q", respZip.Header.Get("Content-Encoding"))
	}
}

func TestStreamSkipsSyncMessagesForLegacyClients(t *testing.T) {
	resetFake(t)
	srcDir := t.TempDir()
	samplePath := filepath.Join(srcDir, "report.pdf")
	if err := os.WriteFile(samplePath, []byte("pdf"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctrl := &sync.Mutex{}
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", inputStreamWithBridge(context.Background(), newReceiver(), ctrl, testToken, newClipboardBridge(), newFileStore()))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/stream", http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var ready streamMessage
	if err := ws.ReadJSON(&ready); err != nil || ready.Type != "ready" {
		t.Fatalf("ready = %+v, err=%v", ready, err)
	}
	setFakeClipboardFiles([]string{samplePath})
	triggerFakeDrop([]string{samplePath})
	var msg streamMessage
	_ = ws.SetReadDeadline(time.Now().Add(700 * time.Millisecond))
	if err := ws.ReadJSON(&msg); err == nil {
		t.Fatalf("legacy client got %+v, want no sync messages", msg)
	}
}

func TestPNGToDIBRejectsHugeDeclaredDimensions(t *testing.T) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 1, 1))); err != nil {
		t.Fatal(err)
	}
	data := buf.Bytes()
	// Rewrite IHDR to claim 8000x8000 (256 MB RGBA) and fix its CRC; DecodeConfig must reject it before decoding.
	binary.BigEndian.PutUint32(data[16:20], 8000)
	binary.BigEndian.PutUint32(data[20:24], 8000)
	binary.BigEndian.PutUint32(data[29:33], crc32.ChecksumIEEE(data[12:29]))
	if _, err := pngToDIB(data); err == nil || !strings.Contains(err.Error(), "dimensions") {
		t.Fatalf("pngToDIB huge = %v, want dimensions error", err)
	}
}

func TestClientFeature(t *testing.T) {
	for header, want := range map[string]bool{"": false, "sync": true, "foo, sync": true, "syncx": false, "foo": false} {
		req := httptest.NewRequest("GET", "/stream", nil)
		if header != "" {
			req.Header.Set("X-Prilo-Features", header)
		}
		if got := clientFeature(req, "sync"); got != want {
			t.Errorf("clientFeature(%q) = %v, want %v", header, got, want)
		}
	}
}

func TestFinalizeUploadKeepsExistingFile(t *testing.T) {
	dir := t.TempDir()
	existing := filepath.Join(dir, "doc.txt")
	if err := os.WriteFile(existing, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	tmp := filepath.Join(dir, ".prilo-upload-1")
	if err := os.WriteFile(tmp, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	path, name, err := finalizeUpload(tmp, dir, "doc.txt")
	if err != nil || name != "doc (2).txt" {
		t.Fatalf("finalizeUpload = (%q, %q, %v)", path, name, err)
	}
	if old, _ := os.ReadFile(existing); string(old) != "old" {
		t.Fatalf("existing file = %q, want untouched", old)
	}
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Fatalf("temp file still present: %v", err)
	}
}

func TestSanitizeFilenameDropsFormatCharacters(t *testing.T) {
	for raw, want := range map[string]string{
		"invoice‮gpj.exe": "invoice_gpj.exe",
		"a​b.txt":         "a_b.txt",
		"CON .txt":        "_CON .txt",
	} {
		if got := sanitizeFilename(raw); got != want {
			t.Errorf("sanitizeFilename(%q) = %q, want %q", raw, got, want)
		}
	}
}
