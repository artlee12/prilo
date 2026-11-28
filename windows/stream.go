package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type inputFrame struct {
	Type      string `json:"type,omitempty"`
	Capture   uint64
	Events    []event
	Clipboard string `json:"clipboard,omitempty"`
	Image     string `json:"image,omitempty"`
	Awake     *bool  `json:"awake,omitempty"`
	Action    string `json:"action,omitempty"`
}

type streamMessage struct {
	Type    string        `json:"type"`
	Capture uint64        `json:"capture,omitempty"`
	Text    string        `json:"text,omitempty"`
	Image   string        `json:"image,omitempty"`
	Files   []offeredFile `json:"files,omitempty"`
}

type clipApplyJob struct {
	kind  string
	text  string
	image string
}

func validEvents(events []event) bool {
	if events == nil || len(events) > 256 {
		return false
	}
	for _, e := range events {
		if !e.valid() {
			return false
		}
	}
	return true
}

// clientFeature reports whether the stream client listed feature in X-Prilo-Features.
func clientFeature(req *http.Request, feature string) bool {
	for _, field := range strings.Split(req.Header.Get("X-Prilo-Features"), ",") {
		if strings.TrimSpace(field) == feature {
			return true
		}
	}
	return false
}

func (r *receiver) releaseAll() {
	r.mu.Lock()
	r.release()
	r.mu.Unlock()
}

func inputStream(r *receiver, control *sync.Mutex, token string) http.HandlerFunc {
	return inputStreamWithBridge(context.Background(), r, control, token, nil, nil)
}

func inputStreamContext(ctx context.Context, r *receiver, control *sync.Mutex, token string) http.HandlerFunc {
	return inputStreamWithBridge(ctx, r, control, token, nil, nil)
}

func inputStreamWithBridge(ctx context.Context, r *receiver, control *sync.Mutex, token string, clip *clipboardBridge, files *fileStore) http.HandlerFunc {
	if clip == nil {
		clip = newClipboardBridge()
	}
	if files == nil {
		files = newFileStore()
	}
	upgrader := websocket.Upgrader{HandshakeTimeout: 3 * time.Second}
	return func(w http.ResponseWriter, req *http.Request) {
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if !control.TryLock() {
			w.WriteHeader(http.StatusConflict)
			return
		}
		defer control.Unlock()
		ws, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		streamCtx, stopStream := context.WithCancel(ctx)
		defer stopStream()
		stopClosing := context.AfterFunc(streamCtx, func() { _ = ws.Close() })
		defer stopClosing()
		defer r.releaseAll()
		ws.SetReadLimit(12 << 20)
		var writeMu sync.Mutex
		write := func(message streamMessage) error {
			writeMu.Lock()
			defer writeMu.Unlock()
			deadline := 2 * time.Second
			if message.Type == "clipboardImage" || message.Type == "fileOffer" || message.Type == "fileDrop" {
				deadline = 5 * time.Second
			}
			_ = ws.SetWriteDeadline(time.Now().Add(deadline))
			return ws.WriteJSON(message)
		}
		if write(streamMessage{Type: "ready"}) != nil {
			return
		}
		// Macs before 0.10 cap stream messages at 4 KB and drop the link on larger ones,
		// so clipboard and file messages go only to clients that announce "sync".
		syncClient := clientFeature(req, "sync")
		var keepAwake atomic.Bool
		var activeCapture atomic.Uint64
		defer activeCapture.Store(0)
		stopDropBar := func() {}
		if syncClient {
			stopDropBar = startDropBar(func(paths []string) {
				offered := files.register(paths)
				if len(offered) > 0 {
					_ = write(streamMessage{Type: "fileDrop", Files: offered})
				}
			})
		}
		defer func() { stopDropBar() }()
		pushClipCh := make(chan struct{}, 1)
		layoutCheckCh := make(chan struct{}, 1)
		applyClipCh := make(chan clipApplyJob, 8)
		enqueuePushClipboard := func() {
			select {
			case pushClipCh <- struct{}{}:
			default:
			}
		}
		triggerLayoutCheck := func() {
			select {
			case layoutCheckCh <- struct{}{}:
			default:
			}
		}
		pushClipboard := func() {
			if !syncClient {
				return
			}
			if item, ok := clip.pollLocal(); ok {
				switch item.kind {
				case "text":
					_ = write(streamMessage{Type: "clipboard", Text: item.text})
				case "image":
					_ = write(streamMessage{
						Type:  "clipboardImage",
						Image: base64.StdEncoding.EncodeToString(item.image),
					})
				case "files":
					offered := files.register(item.files)
					if len(offered) > 0 {
						_ = write(streamMessage{Type: "fileOffer", Files: offered})
					}
				}
			}
		}
		go func() {
			clipTicker := time.NewTicker(250 * time.Millisecond)
			layoutTicker := time.NewTicker(150 * time.Millisecond)
			awakeTicker := time.NewTicker(25 * time.Second)
			defer clipTicker.Stop()
			defer layoutTicker.Stop()
			defer awakeTicker.Stop()
			lastLayout := ""
			var lastReportedCapture uint64
			checkLayout := func(force bool) {
				capID := activeCapture.Load()
				if capID == 0 {
					return
				}
				lang := currentKeyboardLayout()
				if lang == "" {
					return
				}
				if force || capID != lastReportedCapture || lang != lastLayout {
					lastLayout = lang
					lastReportedCapture = capID
					_ = write(streamMessage{Type: "layout", Capture: capID, Text: lang})
				}
			}
			for {
				select {
				case <-streamCtx.Done():
					return
				case <-pushClipCh:
					pushClipboard()
				case <-layoutCheckCh:
					checkLayout(true)
				case <-layoutTicker.C:
					checkLayout(false)
				case <-clipTicker.C:
					pushClipboard()
				case <-awakeTicker.C:
					if keepAwake.Load() {
						pulseKeepAwake()
					}
				}
			}
		}()
		go func() {
			for {
				select {
				case <-streamCtx.Done():
					return
				case job := <-applyClipCh:
					applyClipJob(clip, job)
				}
			}
		}()
		var capture uint64
		var lastCapture uint64
		var lastDeadline time.Time
		for {
			now := time.Now()
			if capture != lastCapture || now.Sub(lastDeadline) >= time.Second {
				readTimeout := 15 * time.Second
				if capture != 0 {
					readTimeout = 6 * time.Second
				}
				_ = ws.SetReadDeadline(now.Add(readTimeout))
				lastCapture = capture
				lastDeadline = now
			}
			kind, data, err := ws.ReadMessage()
			if err != nil {
				return
			}
			var frame inputFrame
			if (kind != websocket.TextMessage && kind != websocket.BinaryMessage) ||
				json.Unmarshal(data, &frame) != nil {
				_ = write(streamMessage{Type: "invalid"})
				return
			}
			switch frame.Type {
			case "clipboard":
				if len(frame.Clipboard) <= maxClipboardBytes {
					select {
					case applyClipCh <- clipApplyJob{kind: "text", text: frame.Clipboard}:
					default:
					}
				}
				continue
			case "clipboardImage":
				if len(frame.Image) > 0 && len(frame.Image) <= base64.StdEncoding.EncodedLen(maxClipboardImageBytes) {
					select {
					case applyClipCh <- clipApplyJob{kind: "image", image: frame.Image}:
					default:
					}
				}
				continue
			case "awake":
				if frame.Awake != nil {
					prev := keepAwake.Swap(*frame.Awake)
					if *frame.Awake && !prev {
						pulseKeepAwake()
					}
				}
				continue
			case "shortcut":
				if capture != 0 && frame.Capture == capture && validShortcutAction(frame.Action) {
					r.mu.Lock()
					if !r.stopped {
						r.last = time.Now()
						if frame.Action == "snip" {
							r.release()
						}
						if err := sendShortcut(frame.Action); err != nil {
							log.Printf("stream shortcut %s: %v", frame.Action, err)
						}
					}
					r.mu.Unlock()
				}
				continue
			}
			if !validEvents(frame.Events) {
				_ = write(streamMessage{Type: "invalid"})
				return
			}
			if len(frame.Events) == 0 {
				_, _ = r.apply(frame.Events)
				continue
			}
			if frame.Capture == 0 {
				continue
			}
			first := frame.Events[0].Kind
			if first == "enter" {
				r.releaseAll()
				capture = frame.Capture
				activeCapture.Store(capture)
			}
			if frame.Capture != capture {
				continue
			}
			returned, err := r.apply(frame.Events)
			if err != nil {
				log.Printf("stream input: %v", err)
				_ = write(streamMessage{Type: "inputUnavailable", Capture: capture})
				return
			}
			if returned || first == "release" {
				enqueuePushClipboard()
				if returned && write(streamMessage{Type: "returned", Capture: capture}) != nil {
					return
				}
				capture = 0
				activeCapture.Store(0)
			} else if first == "enter" {
				if write(streamMessage{Type: "entered", Capture: capture}) != nil {
					return
				}
				triggerLayoutCheck()
			}
		}
	}
}

// applyClipJob writes a remote clipboard update; a panic in image conversion must not stop the receiver.
func applyClipJob(clip *clipboardBridge, job clipApplyJob) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("clipboard apply panic: %v", r)
		}
	}()
	switch job.kind {
	case "text":
		if err := clip.applyRemote(job.text); err != nil {
			log.Printf("clipboard apply: %v", err)
		}
	case "image":
		pngBytes, err := base64.StdEncoding.DecodeString(job.image)
		if err == nil && len(pngBytes) > 0 && len(pngBytes) <= maxClipboardImageBytes {
			if err := clip.applyRemoteImage(pngBytes); err != nil {
				log.Printf("clipboard image apply: %v", err)
			}
		}
	}
}
