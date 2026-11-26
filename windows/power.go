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
	mu   sync.Mutex
	last time.Time
	lock func() error
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
	mux.HandleFunc("/power/lock", func(w http.ResponseWriter, req *http.Request) {
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
		p.mu.Lock()
		defer p.mu.Unlock()
		if time.Since(p.last) >= 2*time.Second {
			if err := p.lock(); err != nil {
				log.Printf("Lock workstation failed: %v", err)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			p.last = time.Now()
		}
		w.WriteHeader(http.StatusAccepted)
	})
}
