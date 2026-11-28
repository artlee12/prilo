//go:build !windows

package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestVPNEndpoints(t *testing.T) {
	var opened []string
	var failure error
	vpn := &vpnController{open: func(link string) error {
		if failure != nil {
			return failure
		}
		opened = append(opened, link)
		return nil
	}}
	token := powerToken(testToken)
	mux := http.NewServeMux()
	vpn.register(mux, token)
	do := func(method, path, auth string) int {
		req := httptest.NewRequest(method, path, nil)
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code
	}

	if code := do("POST", "/vpn/connect", testToken); code != http.StatusUnauthorized {
		t.Errorf("input token = %d, want 401", code)
	}
	if code := do("GET", "/vpn/connect", token); code != http.StatusMethodNotAllowed {
		t.Errorf("GET = %d, want 405", code)
	}
	failure = errHappMissing
	if code := do("POST", "/vpn/connect", token); code != http.StatusFailedDependency {
		t.Errorf("Happ missing = %d, want 424", code)
	}
	failure = errors.New("shell failed")
	if code := do("POST", "/vpn/connect", token); code != http.StatusServiceUnavailable {
		t.Errorf("shell failure = %d, want 503", code)
	}
	failure = nil
	if code := do("POST", "/vpn/connect", token); code != http.StatusAccepted {
		t.Errorf("connect = %d, want 202", code)
	}
	if code := do("POST", "/vpn/disconnect", token); code != http.StatusTooManyRequests {
		t.Errorf("command within 1 s = %d, want 429", code)
	}
	vpn.last = vpn.last.Add(-2 * time.Second)
	if code := do("POST", "/vpn/disconnect", token); code != http.StatusAccepted {
		t.Errorf("disconnect = %d, want 202", code)
	}
	want := []string{"happ://open", "happ://disconnect"}
	if len(opened) != 2 || opened[0] != want[0] || opened[1] != want[1] {
		t.Fatalf("opened %v, want %v", opened, want)
	}
}
