package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/grandcat/zeroconf"
)

type pairingInvite struct {
	mu          sync.Mutex
	pin         string
	code        string
	expires     time.Time
	attempts    int
	fingerprint string
}

// issue replaces the one-time pairing code. It is valid for 10 minutes and works once.
func (p *pairingInvite) issue() (string, error) {
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pin = fmt.Sprintf("%06d", number.Int64())
	p.expires = time.Now().Add(10 * time.Minute)
	p.attempts = 8
	prefix := strings.ToUpper(p.fingerprint[:16])
	p.code = fmt.Sprintf("%s-%s-%s-%s-%s", prefix[:4], prefix[4:8], prefix[8:12], prefix[12:16], p.pin)
	log.Print("New pairing code issued")
	return p.code, nil
}

// current returns the pairing code while it can still be used.
func (p *pairingInvite) current(now time.Time) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.pin == "" || p.attempts == 0 || !now.Before(p.expires) {
		return "", false
	}
	return p.code, true
}

func (p *pairingInvite) matches(pin string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.attempts == 0 || !now.Before(p.expires) {
		return false
	}
	p.attempts--
	if subtle.ConstantTimeCompare([]byte(p.pin), []byte(pin)) != 1 {
		return false
	}
	p.pin = ""
	p.code = ""
	p.attempts = 0
	return true
}

func (p *pairingInvite) register(mux *http.ServeMux, token string) {
	mux.HandleFunc("/pair", func(w http.ResponseWriter, req *http.Request) {
		rc := http.NewResponseController(w)
		_ = rc.SetReadDeadline(time.Now().Add(5 * time.Second))
		_ = rc.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if req.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		var input struct{ PIN string }
		if json.NewDecoder(http.MaxBytesReader(w, req.Body, 128)).Decode(&input) != nil || len(input.PIN) != 6 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if !p.matches(input.PIN, time.Now()) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		writeJSON(w, map[string]string{"code": token})
	})
}

type wakeAdapter struct {
	Name      string
	IP        string
	MAC       string
	Broadcast string
}

// connectionDetails is the text for manual setup on the Mac. It contains the access code.
func connectionDetails(token, fingerprint string) string {
	var b strings.Builder
	b.WriteString("Данные для ручного подключения в Prilo на Mac.\n\n")
	addresses, _ := net.InterfaceAddrs()
	for _, address := range addresses {
		if ip, ok := address.(*net.IPNet); ok && ip.IP.To4() != nil && !ip.IP.IsLoopback() && !ip.IP.IsLinkLocalUnicast() {
			fmt.Fprintf(&b, "IP-адрес Windows: %s\n", ip.IP)
		}
	}
	fmt.Fprintf(&b, "Код доступа: %s\nОтпечаток сертификата: %s\n", token, fingerprint)
	for _, adapter := range wakeAdapters() {
		fmt.Fprintf(&b, "\nWake-on-LAN: %s\nMAC %s · Broadcast %s\n", adapter.Name, adapter.MAC, adapter.Broadcast)
	}
	b.WriteString("\nХрани код доступа в секрете.")
	return b.String()
}

func wakeAdapters() []wakeAdapter {
	var result []wakeAdapter
	adapters, _ := net.Interfaces()
	for _, adapter := range adapters {
		if adapter.Flags&net.FlagUp == 0 || len(adapter.HardwareAddr) != 6 {
			continue
		}
		addresses, _ := adapter.Addrs()
		for _, address := range addresses {
			ip, ok := address.(*net.IPNet)
			if !ok || ip.IP.To4() == nil || ip.IP.IsLinkLocalUnicast() || ip.IP.IsLoopback() || len(ip.Mask) != 4 {
				continue
			}
			broadcast := append(net.IP(nil), ip.IP.To4()...)
			for index := range broadcast {
				broadcast[index] |= ^ip.Mask[index]
			}
			result = append(result, wakeAdapter{adapter.Name, ip.IP.String(), adapter.HardwareAddr.String(), broadcast.String()})
		}
	}
	return result
}

func advertise(name, fingerprint string) (*zeroconf.Server, error) {
	// Use the identity suffix to keep equally named Windows installations distinct.
	instance := name + "-" + fingerprint[:6]
	return zeroconf.Register(instance, "_prilo._tcp", "local.", 43821,
		[]string{"v=1", "fingerprint=" + fingerprint, "name=" + name}, nil)
}

func keepAdvertising(ctx context.Context, name, fingerprint string) {
	var current *zeroconf.Server
	defer func() {
		if current != nil {
			current.Shutdown()
		}
	}()
	var previous string
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		var network []string
		for _, adapter := range wakeAdapters() {
			network = append(network, adapter.IP+"/"+adapter.Broadcast)
		}
		sort.Strings(network)
		signature := strings.Join(network, ",")
		if signature != previous || current == nil {
			if current != nil {
				current.Shutdown()
				current = nil
			}
			if signature != "" {
				next, err := advertise(name, fingerprint)
				if err != nil {
					if signature != previous {
						log.Printf("Local discovery unavailable: %v", err)
					}
				} else {
					current = next
					log.Print("Prilo discovery ready")
				}
			}
			previous = signature
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func deviceInfo(token string) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
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
		info := map[string]string{"stream": "1", "shortcut": "1", "files": "1", "sync": "1"}
		if address, ok := req.Context().Value(http.LocalAddrContextKey).(*net.TCPAddr); ok {
			for _, adapter := range wakeAdapters() {
				if adapter.IP == address.IP.String() {
					info["mac"] = adapter.MAC
					info["broadcast"] = adapter.Broadcast
					break
				}
			}
		}
		writeJSON(w, info)
	}
}

func writeJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(body)
}
