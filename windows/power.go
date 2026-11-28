package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"log"
	"net/http"
	"sync"
	"time"
)

type powerController struct {
	lockMu       sync.Mutex
	shutdownMu   sync.Mutex
	last         time.Time
	lastShutdown time.Time
	lock         func() error
	// shutdown keeps /power/shutdown working for Homebridge plugin 0.9, which turns the PC off.
	shutdown func() error
}

func powerToken(inputToken string) string {
	mac := hmac.New(sha256.New, []byte(inputToken))
	mac.Write([]byte("prilo-power-v1"))
	return hex.EncodeToString(mac.Sum(nil))
}

func (p *powerController) register(mux *http.ServeMux, token string) {
	mux.HandleFunc("/power/status", func(w http.ResponseWriter, req *http.Request) {
		rc := http.NewResponseController(w)
		_ = rc.SetReadDeadline(time.Now().Add(5 * time.Second))
		_ = rc.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if req.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/power/lock", p.action(token, "Lock workstation", 2*time.Second, &p.lockMu, &p.last, p.lock))
	mux.HandleFunc("/power/shutdown", p.action(token, "Power shutdown", 10*time.Second, &p.shutdownMu, &p.lastShutdown, p.shutdown))
}

// action serves a rate-limited POST endpoint; repeats inside the interval succeed without acting again.
func (p *powerController) action(token, name string, interval time.Duration, mu *sync.Mutex, last *time.Time, fn func() error) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		rc := http.NewResponseController(w)
		_ = rc.SetReadDeadline(time.Now().Add(5 * time.Second))
		_ = rc.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if req.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if fn == nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if time.Since(*last) >= interval {
			if err := fn(); err != nil {
				log.Printf("%s failed: %v", name, err)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			*last = time.Now()
		}
		w.WriteHeader(http.StatusAccepted)
	}
}
