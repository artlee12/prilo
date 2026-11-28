//go:build !windows

// Test doubles for the Windows-only input layer, so the receiver logic runs on macOS and Linux.
package main

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

var fake struct {
	mu           sync.Mutex
	sent         []event
	failKey      uint16 // key-up for this code fails while non-zero
	err          error  // every send fails while non-nil
	bottom       bool
	clipSeq      uint32
	clipText     string
	clipHasText  bool
	clipImage    []byte
	clipHasImage bool
	clipFiles    []string
	clipHasFiles bool
	awakePulses  int
	shortcuts    []string
	dropHandler  func([]string)
	layout       string
}

func (e event) send() error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.err != nil {
		return fake.err
	}
	if fake.failKey != 0 && e.Kind == "key" && e.Code == fake.failKey && !e.Down {
		return errFake
	}
	fake.sent = append(fake.sent, e)
	return nil
}

func atBottom() bool {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.bottom
}

func setDPIAware()                  {}
func startupOption() (bool, error)  { return false, nil }
func loadPairing() (pairing, error) { return pairing{}, nil }
func lockWindows() error            { return nil }
func shutdownWindows() error        { return nil }
func openHappLink(string) error     { return nil }
func showError(string)              {}
func runTray(*trayApp)              {}

func resolveFileDestination(dest string) (string, error) {
	return filepath.Join(os.TempDir(), "prilo-test", dest), nil
}

func pulseKeepAwake() {
	fake.mu.Lock()
	fake.awakePulses++
	fake.mu.Unlock()
}

func sendShortcut(action string) error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.err != nil {
		return fake.err
	}
	fake.shortcuts = append(fake.shortcuts, action)
	return nil
}

func setFakeLayout(code string) {
	fake.mu.Lock()
	fake.layout = code
	fake.mu.Unlock()
}

func currentKeyboardLayout() string {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.layout
}

func startDropBar(onDrop func([]string)) func() {
	fake.mu.Lock()
	fake.dropHandler = onDrop
	fake.mu.Unlock()
	return func() {
		fake.mu.Lock()
		fake.dropHandler = nil
		fake.mu.Unlock()
	}
}

func triggerFakeDrop(paths []string) {
	fake.mu.Lock()
	fn := fake.dropHandler
	fake.mu.Unlock()
	if fn != nil {
		fn(paths)
	}
}

type trayApp struct {
	invite  *pairingInvite
	details func() string
	quit    func()
}

var launchedAtLogin, launchedAfterUpdate bool

func cleanupOldExe() {}

type fakeError string

func (e fakeError) Error() string { return string(e) }

const errFake = fakeError("injected send failure")

func getClipboardSequenceNumber() uint32 {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.clipSeq
}

func getClipboardContent() (clipboardItem, bool, error) {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.clipHasFiles {
		return clipboardItem{kind: "files", files: append([]string(nil), fake.clipFiles...)}, true, nil
	}
	if fake.clipHasText {
		return clipboardItem{kind: "text", text: fake.clipText}, true, nil
	}
	if fake.clipHasImage {
		return clipboardItem{kind: "image", image: append([]byte(nil), fake.clipImage...)}, true, nil
	}
	return clipboardItem{}, false, nil
}

func setClipboardText(text string) error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	fake.clipSeq++
	fake.clipText = text
	fake.clipHasText = true
	fake.clipImage = nil
	fake.clipHasImage = false
	fake.clipFiles = nil
	fake.clipHasFiles = false
	return nil
}

func setClipboardImage(pngData []byte) error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	fake.clipSeq++
	fake.clipText = ""
	fake.clipHasText = false
	fake.clipImage = append([]byte(nil), pngData...)
	fake.clipHasImage = true
	fake.clipFiles = nil
	fake.clipHasFiles = false
	return nil
}

func setClipboardFiles(paths []string) error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	fake.clipSeq++
	fake.clipText = ""
	fake.clipHasText = false
	fake.clipImage = nil
	fake.clipHasImage = false
	fake.clipFiles = append([]string(nil), paths...)
	fake.clipHasFiles = true
	return nil
}

func resetFake(t *testing.T) {
	t.Helper()
	fake.mu.Lock()
	fake.sent, fake.failKey, fake.err, fake.bottom = nil, 0, nil, false
	fake.clipSeq, fake.clipText, fake.clipHasText = 0, "", false
	fake.clipImage, fake.clipHasImage = nil, false
	fake.clipFiles, fake.clipHasFiles = nil, false
	fake.awakePulses = 0
	fake.shortcuts = nil
	fake.dropHandler = nil
	fake.layout = ""
	fake.mu.Unlock()
}

func awakePulses() int {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.awakePulses
}

func sentShortcuts() []string {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return append([]string(nil), fake.shortcuts...)
}

func sentEvents() []event {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return append([]event(nil), fake.sent...)
}

func setBottom(value bool) {
	fake.mu.Lock()
	fake.bottom = value
	fake.mu.Unlock()
}

func setFakeClipboard(text string) {
	fake.mu.Lock()
	fake.clipSeq++
	fake.clipText = text
	fake.clipHasText = true
	fake.clipImage = nil
	fake.clipHasImage = false
	fake.mu.Unlock()
}

func setFakeClipboardImage(pngData []byte) {
	fake.mu.Lock()
	fake.clipSeq++
	fake.clipText = ""
	fake.clipHasText = false
	fake.clipImage = append([]byte(nil), pngData...)
	fake.clipHasImage = true
	fake.clipFiles = nil
	fake.clipHasFiles = false
	fake.mu.Unlock()
}

func setFakeClipboardFiles(paths []string) {
	fake.mu.Lock()
	fake.clipSeq++
	fake.clipText = ""
	fake.clipHasText = false
	fake.clipImage = nil
	fake.clipHasImage = false
	fake.clipFiles = append([]string(nil), paths...)
	fake.clipHasFiles = true
	fake.mu.Unlock()
}

func fakeClipboard() string {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.clipText
}

func fakeClipboardImage() []byte {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return append([]byte(nil), fake.clipImage...)
}

func fakeClipboardFiles() []string {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return append([]string(nil), fake.clipFiles...)
}
