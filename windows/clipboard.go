package main

import (
	"crypto/sha256"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

const maxClipboardBytes = 512 << 10

type clipboardItem struct {
	kind  string
	text  string
	image []byte
	files []string
}

func normalizeClipboardNewlines(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	return strings.ReplaceAll(text, "\r", "\n")
}

func windowsClipboardNewlines(text string) string {
	canonical := strings.ReplaceAll(normalizeClipboardNewlines(text), "\x00", "")
	return strings.ReplaceAll(canonical, "\n", "\r\n")
}

func clipboardDigest(kind string, payload []byte) [32]byte {
	h := sha256.New()
	_, _ = h.Write([]byte(kind))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write(payload)
	var sum [32]byte
	copy(sum[:], h.Sum(nil))
	return sum
}

type clipboardBridge struct {
	mu       sync.Mutex
	lastSeq  uint32
	lastHash [32]byte
	hasHash  bool
}

func newClipboardBridge() *clipboardBridge {
	return &clipboardBridge{lastSeq: getClipboardSequenceNumber()}
}

func (b *clipboardBridge) applyRemote(text string) error {
	if len(text) == 0 || len(text) > maxClipboardBytes {
		return nil
	}
	canonical := strings.ReplaceAll(normalizeClipboardNewlines(text), "\x00", "")
	if canonical == "" || len(canonical) > maxClipboardBytes {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := setClipboardText(windowsClipboardNewlines(canonical)); err != nil {
		return err
	}
	b.lastHash = clipboardDigest("text", []byte(canonical))
	b.hasHash = true
	b.lastSeq = getClipboardSequenceNumber()
	return nil
}

func (b *clipboardBridge) applyRemoteImage(pngData []byte) error {
	if len(pngData) == 0 || len(pngData) > maxClipboardImageBytes {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := setClipboardImage(pngData); err != nil {
		return err
	}
	b.lastHash = clipboardDigest("image", pngData)
	b.hasHash = true
	b.lastSeq = getClipboardSequenceNumber()
	return nil
}

func filesDigest(paths []string) ([32]byte, []string) {
	cleaned := make([]string, 0, len(paths))
	for _, p := range paths {
		if c := strings.TrimSpace(p); c != "" {
			cleaned = append(cleaned, filepath.Clean(c))
		}
	}
	normalized := make([]string, len(cleaned))
	copy(normalized, cleaned)
	sort.Strings(normalized)
	return clipboardDigest("files", []byte(strings.Join(normalized, "\x00"))), cleaned
}

func (b *clipboardBridge) applyRemoteFiles(paths []string) error {
	if len(paths) == 0 {
		return nil
	}
	sum, cleaned := filesDigest(paths)
	if len(cleaned) == 0 {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := setClipboardFiles(cleaned); err != nil {
		return err
	}
	b.lastHash = sum
	b.hasHash = true
	b.lastSeq = getClipboardSequenceNumber()
	return nil
}

func (b *clipboardBridge) pollLocal() (clipboardItem, bool) {
	seq := getClipboardSequenceNumber()
	b.mu.Lock()
	unchanged := seq == b.lastSeq
	b.mu.Unlock()
	if unchanged {
		return clipboardItem{}, false
	}

	item, ok, err := getClipboardContent()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.lastSeq == seq {
		return clipboardItem{}, false
	}
	if err != nil {
		return clipboardItem{}, false
	}
	b.lastSeq = seq
	if !ok {
		b.hasHash = false
		return clipboardItem{}, false
	}
	switch item.kind {
	case "files":
		sum, cleaned := filesDigest(item.files)
		if len(cleaned) == 0 {
			b.hasHash = false
			return clipboardItem{}, false
		}
		if b.hasHash && sum == b.lastHash {
			return clipboardItem{}, false
		}
		b.lastHash = sum
		b.hasHash = true
		return clipboardItem{kind: "files", files: cleaned}, true
	case "text":
		if len(item.text) == 0 || len(item.text) > maxClipboardBytes {
			b.hasHash = false
			return clipboardItem{}, false
		}
		canonical := strings.ReplaceAll(normalizeClipboardNewlines(item.text), "\x00", "")
		if canonical == "" || len(canonical) > maxClipboardBytes {
			b.hasHash = false
			return clipboardItem{}, false
		}
		sum := clipboardDigest("text", []byte(canonical))
		if b.hasHash && sum == b.lastHash {
			return clipboardItem{}, false
		}
		b.lastHash = sum
		b.hasHash = true
		return clipboardItem{kind: "text", text: canonical}, true
	case "image":
		if len(item.image) == 0 || len(item.image) > maxClipboardImageBytes {
			b.hasHash = false
			return clipboardItem{}, false
		}
		sum := clipboardDigest("image", item.image)
		if b.hasHash && sum == b.lastHash {
			return clipboardItem{}, false
		}
		b.lastHash = sum
		b.hasHash = true
		return item, true
	default:
		b.hasHash = false
		return clipboardItem{}, false
	}
}
