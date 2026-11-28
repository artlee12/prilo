package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type event struct {
	Kind string
	X, Y int32
	Code uint16
	Down bool
}

const (
	bottomReturnPush int32 = 60
	bottomPushWindow       = 250 * time.Millisecond
)

func abs32(v int32) int32 {
	if v < 0 {
		return -v
	}
	return v
}

type receiver struct {
	stopped        bool
	mu             sync.Mutex
	last           time.Time
	bottomPush     int32
	lastBottomPush time.Time
	enteredAt      time.Time
	keys           map[uint16]bool
	buttons        map[uint16]bool
}

func (r *receiver) release() {
	for code := range r.keys {
		if (event{Kind: "key", Code: code}).send() == nil {
			delete(r.keys, code)
		}
	}
	for code := range r.buttons {
		if (event{Kind: "button", Code: code}).send() == nil {
			delete(r.buttons, code)
		}
	}
}

func (r *receiver) apply(events []event) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stopped {
		return false, http.ErrServerClosed
	}
	now := time.Now()
	r.last = now
	for _, e := range events {
		if e.Kind == "release" {
			r.release()
			continue
		}
		if e.Kind == "enter" {
			r.bottomPush = 0
			r.lastBottomPush = time.Time{}
			r.enteredAt = now
		}
		if e.Kind == "button" {
			r.bottomPush = 0
		}
		if e.Kind == "move" {
			if len(r.buttons) == 0 && e.Y > 0 && abs32(e.X) <= e.Y && now.Sub(r.enteredAt) >= 200*time.Millisecond && atBottom() {
				if !r.lastBottomPush.IsZero() && now.Sub(r.lastBottomPush) > bottomPushWindow {
					r.bottomPush = 0
				}
				r.lastBottomPush = now
				r.bottomPush += e.Y
				if r.bottomPush >= bottomReturnPush {
					r.bottomPush = 0
					r.release()
					return true, nil
				}
			} else if e.Y != 0 || e.X != 0 {
				r.bottomPush = 0
			}
		}
		if err := e.send(); err != nil {
			return false, err
		}
		var held map[uint16]bool
		switch e.Kind {
		case "key":
			held = r.keys
		case "button":
			held = r.buttons
		}
		if held != nil {
			if e.Down {
				held[e.Code] = true
			} else {
				delete(held, e.Code)
			}
		}
	}
	return false, nil
}

func certificate() ([]byte, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serialBound := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialBound)
	if err != nil {
		return nil, nil, err
	}
	template := &x509.Certificate{
		SerialNumber: serial,
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().AddDate(10, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey}), nil
}

func (e event) valid() bool {
	switch e.Kind {
	case "release":
		return true
	case "enter":
		return e.X >= 0 && e.X <= 65535
	case "move", "scroll":
		return e.X >= -10000 && e.X <= 10000 && e.Y >= -10000 && e.Y <= 10000
	case "button":
		return e.Code <= 2
	case "key":
		return e.Code > 0 && e.Code <= 0x17f && e.Code != 0x100
	}
	return false
}

func authorized(req *http.Request, token string) bool {
	header := req.Header.Get("Authorization")
	return strings.HasPrefix(header, "Bearer ") &&
		subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(header, "Bearer ")), []byte(token)) == 1
}

// fatal records the error and shows it, since the receiver runs without a console.
func fatal(message string, err error) {
	log.Printf("%s: %v", message, err)
	showError(message + "\n\n" + err.Error())
	os.Exit(1)
}

func main() {
	closeLog := setupLog()
	defer closeLog()
	done, err := startupOption()
	if err != nil {
		fatal("Не удалось выполнить команду", err)
	}
	if done {
		return
	}
	setDPIAware()
	cleanupOldExe()
	service, err := startReceiver(func(err error) {
		fatal("Приёмник Fuso остановился", err)
	})
	if err != nil {
		fatal("Не удалось запустить Fuso Receiver", err)
	}
	defer service.close()
	runTray(&trayApp{
		invite:  service.invite,
		details: service.details,
		quit:    service.close,
	})
}

type receiverService struct {
	listener      net.Listener
	server        *http.Server
	input         *receiver
	invite        *pairingInvite
	details       func() string
	cancel        context.CancelFunc
	done          <-chan struct{}
	discoveryDone <-chan struct{}
	stop          sync.Once
}

func (s *receiverService) close() {
	s.stop.Do(func() {
		s.input.mu.Lock()
		s.input.stopped = true
		s.input.release()
		s.input.mu.Unlock()
		s.cancel()
		_ = s.server.Close()
		_ = s.listener.Close()
		<-s.discoveryDone
		for attempt := 0; attempt < 3; attempt++ {
			s.input.mu.Lock()
			pending := len(s.input.keys) + len(s.input.buttons)
			if pending == 0 {
				s.input.mu.Unlock()
				break
			}
			s.input.release()
			s.input.mu.Unlock()
			time.Sleep(50 * time.Millisecond)
		}
		s.input.mu.Lock()
		if len(s.input.keys)+len(s.input.buttons) != 0 {
			log.Print("Windows did not accept all input releases during shutdown")
		}
		s.input.mu.Unlock()
		log.Print("Prilo receiver stopped")
	})
}

func startReceiver(onServerError func(error)) (*receiverService, error) {
	listener, err := net.Listen("tcp4", ":43821")
	// After a self-update the previous copy may still be closing its listener.
	for wait := 0; err != nil && launchedAfterUpdate && wait < 40; wait++ {
		time.Sleep(250 * time.Millisecond)
		listener, err = net.Listen("tcp4", ":43821")
	}
	if err != nil {
		return nil, fmt.Errorf("TCP 43821: %w", err)
	}
	saved, err := loadPairing()
	if err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("load Prilo keys: %w", err)
	}
	cert, fingerprint, err := saved.credentials()
	if err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("read Prilo keys: %w", err)
	}
	token := saved.Token
	log.Printf("Prilo receiver %s started (autostart=%v, updated=%v)", version, launchedAtLogin, launchedAfterUpdate)

	name, _ := os.Hostname()
	if name == "" {
		name = "Windows"
	}
	ctx, cancel := context.WithCancel(context.Background())
	discoveryDone := make(chan struct{})
	go func() {
		defer close(discoveryDone)
		keepAdvertising(ctx, name, fingerprint)
	}()
	invite := &pairingInvite{fingerprint: fingerprint}
	if _, err := invite.issue(); err != nil {
		log.Printf("Pairing code: %v", err)
	}

	r := &receiver{keys: make(map[uint16]bool), buttons: make(map[uint16]bool)}
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			r.mu.Lock()
			if time.Since(r.last) > 2*time.Second {
				r.release()
			}
			r.mu.Unlock()
		}
	}()

	mux := http.NewServeMux()
	var control sync.Mutex
	clip := newClipboardBridge()
	files := newFileStore()
	mux.HandleFunc("/stream", inputStreamWithBridge(ctx, r, &control, token, clip, files))
	mux.HandleFunc("/device", deviceInfo(token))
	mux.HandleFunc("/file", handleFileUpload(token, clip, files, resolveFileDestination))
	mux.HandleFunc("/file/download", handleFileDownload(token, files))
	invite.register(mux, token)
	power := &powerController{lock: lockWindows, shutdown: shutdownWindows}
	power.register(mux, powerToken(token))
	vpn := &vpnController{open: openHappLink}
	vpn.register(mux, powerToken(token))
	mux.HandleFunc("/input", func(w http.ResponseWriter, req *http.Request) {
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
		var events []event
		err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 32768)).Decode(&events)
		if err != nil || !validEvents(events) {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if !control.TryLock() {
			w.WriteHeader(http.StatusConflict)
			return
		}
		defer control.Unlock()
		returned, err := r.apply(events)
		if err != nil {
			log.Print(err)
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if returned {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	server := &http.Server{
		Handler:           mux,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 5 * time.Second,
		// Defaults for every route; /file and /file/download extend their own deadlines.
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  30 * time.Second,
	}
	service := &receiverService{listener: listener, server: server, input: r, invite: invite, cancel: cancel, done: ctx.Done(), discoveryDone: discoveryDone,
		details: func() string { return connectionDetails(token, fingerprint) }}
	go func() {
		if err := server.ServeTLS(listener, "", ""); !errors.Is(err, http.ErrServerClosed) {
			log.Printf("Prilo receiver stopped unexpectedly: %v", err)
			service.close()
			if onServerError != nil {
				onServerError(err)
			}
		}
	}()
	return service, nil
}
