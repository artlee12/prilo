package main

import (
	"errors"
	"log"
	"net/http"
	"sync"
	"time"
)

// errHappMissing means Windows has no handler for happ:// links, i.e. Happ is not installed.
var errHappMissing = errors.New("Happ is not installed")

// vpnController turns the VPN on or off through the Happ client on this PC.
// It uses the scoped power token, like /power/*.
type vpnController struct {
	mu   sync.Mutex
	last time.Time
	open func(link string) error
}

func (v *vpnController) register(mux *http.ServeMux, token string) {
	for path, link := range map[string]string{
		"/vpn/connect":    "happ://open",
		"/vpn/disconnect": "happ://disconnect",
	} {
		link := link
		mux.HandleFunc(path, func(w http.ResponseWriter, req *http.Request) {
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
			if !v.mu.TryLock() {
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			defer v.mu.Unlock()
			if time.Since(v.last) < time.Second {
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			err := v.open(link)
			switch {
			case errors.Is(err, errHappMissing):
				w.WriteHeader(http.StatusFailedDependency)
			case err != nil:
				log.Printf("VPN command failed: %v", err)
				w.WriteHeader(http.StatusServiceUnavailable)
			default:
				v.last = time.Now()
				w.WriteHeader(http.StatusAccepted)
			}
		})
	}
}
