//go:build !windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testToken = "00112233445566778899aabbccddeeff"

func newInvite(t *testing.T) *pairingInvite {
	t.Helper()
	p := &pairingInvite{fingerprint: strings.Repeat("ab", 32)}
	code, err := p.issue()
	if err != nil {
		t.Fatal(err)
	}
	if code != "ABAB-ABAB-ABAB-ABAB-"+p.pin {
		t.Fatalf("code %q does not match fingerprint prefix and pin", code)
	}
	return p
}

func TestPairingCodeWorksOnce(t *testing.T) {
	p := newInvite(t)
	pin := p.pin
	if len(pin) != 6 {
		t.Fatalf("pin %q is not six digits", pin)
	}
	if _, ok := p.current(time.Now()); !ok {
		t.Fatal("fresh code must be shown")
	}
	if !p.matches(pin, time.Now()) {
		t.Fatal("fresh code must match")
	}
	if p.matches(pin, time.Now()) {
		t.Fatal("code must be single-use")
	}
	if _, ok := p.current(time.Now()); ok {
		t.Fatal("a used code must not be shown again")
	}
}

func TestPairingCodeExpires(t *testing.T) {
	p := newInvite(t)
	if _, ok := p.current(time.Now().Add(10 * time.Minute)); ok {
		t.Fatal("expired code must not be shown")
	}
	if p.matches(p.pin, time.Now().Add(10*time.Minute)) {
		t.Fatal("code must stop working after 10 minutes")
	}
}

func TestPairingCodeLocksAfterEightAttempts(t *testing.T) {
	p := newInvite(t)
	wrong := "000000"
	if p.pin == wrong {
		wrong = "111111"
	}
	for i := 0; i < 8; i++ {
		p.matches(wrong, time.Now())
	}
	if p.matches(p.pin, time.Now()) {
		t.Fatal("correct code must be refused after eight wrong attempts")
	}
	if _, err := p.issue(); err != nil {
		t.Fatal(err)
	}
	if !p.matches(p.pin, time.Now()) {
		t.Fatal("a newly issued code must reset the attempt counter")
	}
}

func TestPairEndpoint(t *testing.T) {
	p := newInvite(t)
	mux := http.NewServeMux()
	p.register(mux, testToken)
	post := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest("POST", "/pair", strings.NewReader(body)))
		return rec
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/pair", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET /pair = %d, want 405", rec.Code)
	}
	if rec := post(`{"PIN":"12345"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("short pin = %d, want 400", rec.Code)
	}
	if rec := post(`{"PIN":"` + strings.Repeat("1", 200) + `"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("oversized body = %d, want 400", rec.Code)
	}
	wrong := "000000"
	if p.pin == wrong {
		wrong = "111111"
	}
	if rec := post(`{"PIN":"` + wrong + `"}`); rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong pin = %d, want 401", rec.Code)
	}
	rec = post(`{"PIN":"` + p.pin + `"}`)
	var reply map[string]string
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &reply) != nil || reply["code"] != testToken {
		t.Fatalf("right pin = %d %q, want 200 with the access code", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Error("access code response must not be cacheable")
	}
}

func TestCredentialsFingerprint(t *testing.T) {
	cert, key, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	tlsCert, fingerprint, err := pairing{Certificate: cert, PrivateKey: key, Token: testToken}.credentials()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(tlsCert.Certificate[0])
	if fingerprint != hex.EncodeToString(sum[:]) || len(fingerprint) != 64 {
		t.Fatalf("fingerprint %q is not the SHA-256 of the certificate DER", fingerprint)
	}
	for _, bad := range []string{"", "zz112233445566778899aabbccddeeff", testToken[:30]} {
		if _, _, err := (pairing{Certificate: cert, PrivateKey: key, Token: bad}).credentials(); err == nil {
			t.Errorf("token %q must be rejected", bad)
		}
	}
}

// The Mac app (PowerAccess.code) and the Homebridge export rely on this exact derivation.
func TestPowerTokenDerivation(t *testing.T) {
	const want = "f8bcdd75a07ae2b7135b348261a0321d6b6aba4fc8b067b54928507d65f317b8"
	if got := powerToken(testToken); got != want {
		t.Fatalf("powerToken = %s, want %s", got, want)
	}
}

func TestPowerEndpoints(t *testing.T) {
	calls := 0
	var failure error
	shutdowns := 0
	power := &powerController{
		lock:     func() error { calls++; return failure },
		shutdown: func() error { shutdowns++; return nil },
	}
	token := powerToken(testToken)
	mux := http.NewServeMux()
	power.register(mux, token)
	do := func(method, path, auth string) int {
		req := httptest.NewRequest(method, path, nil)
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code
	}
	if code := do("GET", "/power/status", token); code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", code)
	}
	if code := do("GET", "/power/status", testToken); code != http.StatusUnauthorized {
		t.Errorf("input token on power endpoint = %d, want 401", code)
	}
	if code := do("GET", "/power/lock", token); code != http.StatusMethodNotAllowed {
		t.Errorf("GET lock = %d, want 405", code)
	}
	if code := do("POST", "/power/lock", ""); code != http.StatusUnauthorized || calls != 0 {
		t.Errorf("anonymous lock = %d calls=%d, want 401 and no lock", code, calls)
	}

	failure = errors.New("LockWorkStation failed")
	if code := do("POST", "/power/lock", token); code != http.StatusServiceUnavailable {
		t.Errorf("failed lock = %d, want 503", code)
	}
	failure = nil
	if code := do("POST", "/power/lock", token); code != http.StatusAccepted || calls != 2 {
		t.Errorf("lock after failure = %d calls=%d, want 202 and a retry", code, calls)
	}
	if code := do("POST", "/power/lock", token); code != http.StatusAccepted || calls != 2 {
		t.Errorf("repeat within 2 s = %d calls=%d, want 202 without a second lock", code, calls)
	}
	if code := do("POST", "/power/shutdown", ""); code != http.StatusUnauthorized || shutdowns != 0 {
		t.Errorf("anonymous shutdown = %d shutdowns=%d, want 401 and no shutdown", code, shutdowns)
	}
	if code := do("POST", "/power/shutdown", token); code != http.StatusAccepted || shutdowns != 1 {
		t.Errorf("shutdown = %d shutdowns=%d, want 202 and one shutdown", code, shutdowns)
	}
	if code := do("POST", "/power/shutdown", token); code != http.StatusAccepted || shutdowns != 1 {
		t.Errorf("repeat shutdown = %d shutdowns=%d, want 202 without a second shutdown", code, shutdowns)
	}
}

func TestDeviceInfo(t *testing.T) {
	handler := deviceInfo(testToken)
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("GET", "/device", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("anonymous /device = %d, want 401", rec.Code)
	}
	req := httptest.NewRequest("GET", "/device", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec = httptest.NewRecorder()
	handler(rec, req)
	var info map[string]string
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &info) != nil || info["stream"] != "1" {
		t.Fatalf("/device = %d %q, want stream=1", rec.Code, rec.Body.String())
	}
}
