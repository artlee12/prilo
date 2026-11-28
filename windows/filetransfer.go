package main

import (
	"compress/gzip"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	maxFileUploadBytes    int64 = 512 << 20
	maxClipboardFileBytes int64 = 25 << 20
	maxClipboardFileCount       = 20
	maxStoredOfferedFiles       = 128
)

var copyBufPool = sync.Pool{
	New: func() any {
		buf := make([]byte, 512*1024)
		return &buf
	},
}

func copyWithLargeBuffer(dst io.Writer, src io.Reader) (int64, error) {
	bufPtr := copyBufPool.Get().(*[]byte)
	defer copyBufPool.Put(bufPtr)
	return io.CopyBuffer(dst, src, *bufPtr)
}

var precompressedExts = map[string]bool{
	".zip": true, ".7z": true, ".rar": true, ".gz": true, ".tgz": true, ".bz2": true, ".xz": true, ".zst": true,
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true, ".webp": true, ".heic": true, ".avif": true,
	".mp4": true, ".mov": true, ".mkv": true, ".avi": true, ".webm": true,
	".mp3": true, ".m4a": true, ".aac": true, ".ogg": true, ".flac": true,
	".dmg": true, ".pkg": true, ".whl": true, ".exe": true, ".dll": true,
}

func shouldGzipFile(name string, size int64) bool {
	if size < 4096 {
		return false
	}
	return !precompressedExts[strings.ToLower(filepath.Ext(name))]
}

type offeredFile struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	path      string
	mtimeNano int64
	sourceKey string
}

type fileStore struct {
	mu         sync.Mutex
	files      map[string]offeredFile
	bySource   map[string]string
	order      []string
	batches    map[string][]string
	batchOrder []string
}

func newFileStore() *fileStore {
	return &fileStore{
		files:    make(map[string]offeredFile),
		bySource: make(map[string]string),
		batches:  make(map[string][]string),
	}
}

func (s *fileStore) register(paths []string) []offeredFile {
	out := make([]offeredFile, 0, len(paths))
	seen := make(map[string]bool)
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, rawPath := range paths {
		if len(out) >= maxClipboardFileCount {
			break
		}
		clean := filepath.Clean(rawPath)
		if clean == "" || seen[clean] {
			continue
		}
		seen[clean] = true
		info, err := os.Stat(clean)
		if err != nil || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maxFileUploadBytes {
			continue
		}
		mtimeNano := info.ModTime().UnixNano()
		sourceKey := fmt.Sprintf("%s|%d|%d", clean, info.Size(), mtimeNano)
		if existingID, ok := s.bySource[sourceKey]; ok {
			if existing, exists := s.files[existingID]; exists {
				out = append(out, existing)
				continue
			}
		}
		var token [16]byte
		if _, err := rand.Read(token[:]); err != nil {
			continue
		}
		id := hex.EncodeToString(token[:])
		entry := offeredFile{
			ID:        id,
			Name:      sanitizeFilename(filepath.Base(clean)),
			Size:      info.Size(),
			path:      clean,
			mtimeNano: mtimeNano,
			sourceKey: sourceKey,
		}
		s.files[id] = entry
		s.bySource[sourceKey] = id
		s.order = append(s.order, id)
		for len(s.order) > maxStoredOfferedFiles {
			oldestID := s.order[0]
			s.order = s.order[1:]
			if old, ok := s.files[oldestID]; ok {
				delete(s.bySource, old.sourceKey)
				delete(s.files, oldestID)
			}
		}
		out = append(out, entry)
	}
	return out
}

func (s *fileStore) lookup(id string) (offeredFile, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.files[id]
	return entry, ok
}

func (s *fileStore) recordBatch(batchID, filePath string) []string {
	if batchID == "" {
		return []string{filePath}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.batches[batchID]; !exists {
		s.batchOrder = append(s.batchOrder, batchID)
		for len(s.batchOrder) > 16 {
			oldest := s.batchOrder[0]
			s.batchOrder = s.batchOrder[1:]
			delete(s.batches, oldest)
		}
	}
	s.batches[batchID] = append(s.batches[batchID], filePath)
	out := make([]string, len(s.batches[batchID]))
	copy(out, s.batches[batchID])
	return out
}

var windowsReservedNames = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true,
	"COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true,
	"LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

func truncateUTF8(s string, maxBytes int) string {
	if maxBytes <= 0 {
		return ""
	}
	if len(s) <= maxBytes {
		return s
	}
	bytesUsed := 0
	for idx, r := range s {
		w := utf8.RuneLen(r)
		if w < 0 || bytesUsed+w > maxBytes {
			return s[:idx]
		}
		bytesUsed += w
	}
	return s
}

func sanitizeFilename(raw string) string {
	if unescaped, err := url.PathUnescape(raw); err == nil {
		raw = unescaped
	}
	raw = strings.ReplaceAll(raw, "\\", "/")
	if idx := strings.LastIndex(raw, "/"); idx >= 0 {
		raw = raw[idx+1:]
	}
	var b strings.Builder
	for _, r := range raw {
		// Format characters (bidi overrides, zero-width) can disguise "x\u202Egpj.exe" as "xexe.jpg".
		if r < 0x20 || r == 0x7f || unicode.Is(unicode.Cf, r) || strings.ContainsRune(`<>:"/\|?*`, r) {
			b.WriteByte('_')
		} else {
			b.WriteRune(r)
		}
	}
	cleaned := strings.TrimRight(strings.TrimSpace(b.String()), ". ")
	cleaned = strings.TrimLeft(cleaned, ". ")
	if cleaned == "" || cleaned == "." || cleaned == ".." {
		return "file"
	}
	stem := cleaned
	if dot := strings.IndexByte(cleaned, '.'); dot >= 0 {
		stem = cleaned[:dot]
	}
	if windowsReservedNames[strings.ToUpper(strings.TrimRight(stem, " "))] {
		cleaned = "_" + cleaned
	}
	if len(cleaned) > 180 {
		ext := ""
		if dot := strings.LastIndexByte(cleaned, '.'); dot > 0 && len(cleaned)-dot <= 32 {
			ext = cleaned[dot:]
			base := truncateUTF8(cleaned[:dot], 180-len(ext))
			base = strings.TrimRight(base, ". ")
			if base == "" {
				base = "file"
			}
			cleaned = base + ext
		} else {
			cleaned = truncateUTF8(cleaned, 180)
			cleaned = strings.TrimRight(cleaned, ". ")
		}
	}
	if cleaned == "" {
		return "file"
	}
	return cleaned
}

var finalizeUploadMu sync.Mutex

// finalizeUpload gives the upload a free name. os.Link fails when the name exists, unlike os.Rename on
// Windows, so a file another program creates at the same moment is never replaced.
func finalizeUpload(tmpPath, dir, name string) (string, string, error) {
	finalizeUploadMu.Lock()
	defer finalizeUploadMu.Unlock()
	for attempt := 0; attempt < 8; attempt++ {
		finalPath, finalName, err := uniqueFilePath(dir, name)
		if err != nil {
			return "", "", err
		}
		if err := os.Link(tmpPath, finalPath); err != nil {
			if os.IsExist(err) {
				continue
			}
			// FAT and exFAT have no hard links; the mutex still keeps Prilo's own uploads apart.
			if err := os.Rename(tmpPath, finalPath); err != nil {
				return "", "", err
			}
			return finalPath, finalName, nil
		}
		_ = os.Remove(tmpPath)
		return finalPath, finalName, nil
	}
	return "", "", os.ErrExist
}

// markFromOtherComputer adds the Mark of the Web, so Windows warns before running a received program
// and Office opens received documents in Protected View, as it does for browser downloads.
func markFromOtherComputer(path string) {
	if runtime.GOOS != "windows" {
		return
	}
	if err := os.WriteFile(path+":Zone.Identifier", []byte("[ZoneTransfer]\r\nZoneId=3\r\n"), 0o600); err != nil {
		log.Printf("file upload mark of the web: %v", err)
	}
}

func uniqueFilePath(dir, name string) (string, string, error) {
	candidate := filepath.Join(dir, name)
	if _, err := os.Lstat(candidate); os.IsNotExist(err) {
		return candidate, name, nil
	} else if err != nil {
		return "", "", err
	}
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	if stem == "" {
		stem = "file"
	}
	for n := 2; n < 10000; n++ {
		nextName := stem + " (" + strconv.Itoa(n) + ")" + ext
		nextPath := filepath.Join(dir, nextName)
		if _, err := os.Lstat(nextPath); os.IsNotExist(err) {
			return nextPath, nextName, nil
		} else if err != nil {
			return "", "", err
		}
	}
	return "", "", os.ErrExist
}

func cleanupTempClipboardFiles(dir string, maxAge time.Duration) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-maxAge)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if info.Mode().IsRegular() && info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(dir, entry.Name()))
		}
	}
}

func handleFileUpload(token string, clip *clipboardBridge, store *fileStore, resolveDir func(string) (string, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		rc := http.NewResponseController(w)
		_ = rc.SetReadDeadline(time.Now().Add(10 * time.Minute))
		_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Minute))

		name := sanitizeFilename(req.Header.Get("X-Prilo-Filename"))
		dest := req.Header.Get("X-Prilo-Destination")
		setClipboard := req.Header.Get("X-Prilo-Clipboard") != "0"
		batchID := req.Header.Get("X-Prilo-Batch")

		dir, err := resolveDir(dest)
		if err != nil {
			log.Printf("file upload dir: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			log.Printf("file upload mkdir: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if dest == "clipboard" {
			cleanupTempClipboardFiles(dir, 2*time.Hour)
		}

		tmp, err := os.CreateTemp(dir, ".prilo-upload-*")
		if err != nil {
			log.Printf("file upload create temp: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		tmpPath := tmp.Name()
		removeTmp := true
		defer func() {
			if removeTmp {
				_ = tmp.Close()
				_ = os.Remove(tmpPath)
			}
		}()

		var bodyReader io.Reader = req.Body
		if strings.EqualFold(strings.TrimSpace(req.Header.Get("Content-Encoding")), "gzip") {
			gz, err := gzip.NewReader(req.Body)
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			defer gz.Close()
			bodyReader = gz
		}

		written, err := copyWithLargeBuffer(tmp, io.LimitReader(bodyReader, maxFileUploadBytes+1))
		if err != nil {
			log.Printf("file upload copy: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if written > maxFileUploadBytes {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
			return
		}
		if err := tmp.Close(); err != nil {
			log.Printf("file upload close: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		markFromOtherComputer(tmpPath)
		// os.Rename replaces an existing file on Windows, so picking a free name and renaming must not race.
		finalPath, finalName, err := finalizeUpload(tmpPath, dir, name)
		if err != nil {
			log.Printf("file upload finalize: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		removeTmp = false

		if setClipboard && clip != nil {
			paths := []string{finalPath}
			if store != nil {
				paths = store.recordBatch(batchID, finalPath)
			}
			if err := clip.applyRemoteFiles(paths); err != nil {
				log.Printf("file upload clipboard: %v", err)
			}
		}

		writeJSON(w, map[string]any{
			"name": finalName,
			"path": finalPath,
			"size": written,
		})
	}
}

func handleFileDownload(token string, store *fileStore) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		rc := http.NewResponseController(w)
		_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Minute))

		if store == nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		entry, ok := store.lookup(req.URL.Query().Get("id"))
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		info, err := os.Stat(entry.path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxFileUploadBytes {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f, err := os.Open(entry.path)
		if err != nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		defer f.Close()

		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("X-Prilo-Filename", url.PathEscape(entry.Name))
		w.Header().Set("X-Prilo-Raw-Size", strconv.FormatInt(info.Size(), 10))
		w.Header().Set("Cache-Control", "no-store")
		if strings.Contains(req.Header.Get("Accept-Encoding"), "gzip") && shouldGzipFile(entry.Name, info.Size()) {
			w.Header().Set("Content-Encoding", "gzip")
			w.WriteHeader(http.StatusOK)
			gz, err := gzip.NewWriterLevel(w, gzip.BestSpeed)
			if err != nil {
				return
			}
			_, _ = copyWithLargeBuffer(gz, io.LimitReader(f, info.Size()))
			_ = gz.Close()
			return
		}
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		w.WriteHeader(http.StatusOK)
		_, _ = copyWithLargeBuffer(w, io.LimitReader(f, info.Size()))
	}
}
