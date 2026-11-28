package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const (
	cfDIB         = 8
	cfUnicodeText = 13
	cfHDrop       = 15
	gmemMoveable  = 0x0002
	maxDIBBytes   = 32 << 20
)

var (
	kernel32                   = syscall.NewLazyDLL("kernel32.dll")
	shell32Clip                = syscall.NewLazyDLL("shell32.dll")
	dragQueryFileW             = shell32Clip.NewProc("DragQueryFileW")
	globalAlloc                = kernel32.NewProc("GlobalAlloc")
	globalLock                 = kernel32.NewProc("GlobalLock")
	globalUnlock               = kernel32.NewProc("GlobalUnlock")
	globalSize                 = kernel32.NewProc("GlobalSize")
	globalFree                 = kernel32.NewProc("GlobalFree")
	rtlMoveMemory              = kernel32.NewProc("RtlMoveMemory")
	getClipboardSequenceProc   = user32.NewProc("GetClipboardSequenceNumber")
	isClipboardFormatAvailable = user32.NewProc("IsClipboardFormatAvailable")
	registerClipboardFormatW   = user32.NewProc("RegisterClipboardFormatW")
	openClipboard              = user32.NewProc("OpenClipboard")
	closeClipboard             = user32.NewProc("CloseClipboard")
	emptyClipboard             = user32.NewProc("EmptyClipboard")
	getClipboardData           = user32.NewProc("GetClipboardData")
	setClipboardData           = user32.NewProc("SetClipboardData")
)

var (
	pngFormatOnce sync.Once
	pngFormatID   uintptr
)

func pngClipboardFormat() uintptr {
	pngFormatOnce.Do(func() {
		name, err := syscall.UTF16PtrFromString("PNG")
		if err != nil {
			return
		}
		id, _, _ := registerClipboardFormatW.Call(uintptr(unsafe.Pointer(name)))
		pngFormatID = id
	})
	return pngFormatID
}

func getClipboardSequenceNumber() uint32 {
	seq, _, _ := getClipboardSequenceProc.Call()
	return uint32(seq)
}

func openClipboardWithRetry() error {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		if ok, _, err := openClipboard.Call(0); ok != 0 {
			return nil
		} else {
			lastErr = err
		}
		time.Sleep(15 * time.Millisecond)
	}
	return fmt.Errorf("OpenClipboard: %v", lastErr)
}

func copyGlobalBytes(hMem uintptr, maxLen int) ([]byte, error) {
	size, _, _ := globalSize.Call(hMem)
	if size == 0 || int(size) > maxLen {
		return nil, nil
	}
	src, _, err := globalLock.Call(hMem)
	if src == 0 {
		return nil, fmt.Errorf("GlobalLock: %v", err)
	}
	buf := make([]byte, int(size))
	rtlMoveMemory.Call(uintptr(unsafe.Pointer(&buf[0])), src, size)
	runtime.KeepAlive(buf)
	globalUnlock.Call(hMem)
	return buf, nil
}

func allocGlobalBytes(data []byte) (uintptr, error) {
	hMem, _, err := globalAlloc.Call(gmemMoveable, uintptr(len(data)))
	if hMem == 0 {
		return 0, fmt.Errorf("GlobalAlloc: %v", err)
	}
	dst, _, err := globalLock.Call(hMem)
	if dst == 0 {
		globalFree.Call(hMem)
		return 0, fmt.Errorf("GlobalLock: %v", err)
	}
	rtlMoveMemory.Call(dst, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)))
	runtime.KeepAlive(data)
	globalUnlock.Call(hMem)
	return hMem, nil
}

func getClipboardText() (string, bool, error) {
	avail, _, _ := isClipboardFormatAvailable.Call(cfUnicodeText)
	if avail == 0 {
		return "", false, nil
	}
	if err := openClipboardWithRetry(); err != nil {
		return "", false, err
	}
	defer closeClipboard.Call()

	hMem, _, err := getClipboardData.Call(cfUnicodeText)
	if hMem == 0 {
		if availNow, _, _ := isClipboardFormatAvailable.Call(cfUnicodeText); availNow == 0 {
			return "", false, nil
		}
		return "", false, fmt.Errorf("GetClipboardData: %v", err)
	}
	size, _, _ := globalSize.Call(hMem)
	if size < 2 {
		return "", false, nil
	}
	nChars := int(size / 2)
	maxChars := maxClipboardBytes + 1
	truncated := false
	if nChars > maxChars {
		nChars = maxChars
		truncated = true
	}
	src, _, err := globalLock.Call(hMem)
	if src == 0 {
		return "", false, fmt.Errorf("GlobalLock: %v", err)
	}
	buf := make([]uint16, nChars)
	rtlMoveMemory.Call(uintptr(unsafe.Pointer(&buf[0])), src, uintptr(nChars*2))
	runtime.KeepAlive(buf)
	globalUnlock.Call(hMem)

	hasNul := false
	for _, u := range buf {
		if u == 0 {
			hasNul = true
			break
		}
	}
	if truncated && !hasNul {
		return "", false, nil
	}
	text := syscall.UTF16ToString(buf)
	if len(text) == 0 || len(text) > maxClipboardBytes {
		return "", false, nil
	}
	return text, true, nil
}

func getClipboardFiles() ([]string, bool, error) {
	avail, _, _ := isClipboardFormatAvailable.Call(cfHDrop)
	if avail == 0 {
		return nil, false, nil
	}
	if err := openClipboardWithRetry(); err != nil {
		return nil, false, err
	}
	defer closeClipboard.Call()

	hMem, _, err := getClipboardData.Call(cfHDrop)
	if hMem == 0 {
		if availNow, _, _ := isClipboardFormatAvailable.Call(cfHDrop); availNow == 0 {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("GetClipboardData(CF_HDROP): %v", err)
	}
	count, _, _ := dragQueryFileW.Call(hMem, 0xFFFFFFFF, 0, 0)
	if count == 0 {
		return nil, false, nil
	}
	if count > maxClipboardFileCount {
		count = maxClipboardFileCount
	}
	paths := make([]string, 0, int(count))
	for i := uintptr(0); i < count; i++ {
		chars, _, _ := dragQueryFileW.Call(hMem, i, 0, 0)
		if chars == 0 || chars > 32767 {
			continue
		}
		buf := make([]uint16, int(chars)+1)
		copied, _, _ := dragQueryFileW.Call(hMem, i, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if copied > 0 {
			paths = append(paths, syscall.UTF16ToString(buf[:copied]))
		}
	}
	if len(paths) == 0 {
		return nil, false, nil
	}
	return paths, true, nil
}

func getClipboardContent() (clipboardItem, bool, error) {
	if files, ok, err := getClipboardFiles(); err != nil {
		return clipboardItem{}, false, err
	} else if ok {
		return clipboardItem{kind: "files", files: files}, true, nil
	}

	if text, ok, err := getClipboardText(); err != nil {
		return clipboardItem{}, false, err
	} else if ok {
		return clipboardItem{kind: "text", text: text}, true, nil
	}

	pngFmt := pngClipboardFormat()
	hasPNG := false
	if pngFmt != 0 {
		avail, _, _ := isClipboardFormatAvailable.Call(pngFmt)
		hasPNG = avail != 0
	}
	availDIB, _, _ := isClipboardFormatAvailable.Call(cfDIB)
	hasDIB := availDIB != 0
	if !hasPNG && !hasDIB {
		return clipboardItem{}, false, nil
	}

	if err := openClipboardWithRetry(); err != nil {
		return clipboardItem{}, false, err
	}
	defer closeClipboard.Call()

	if hasPNG {
		if hMem, _, _ := getClipboardData.Call(pngFmt); hMem != 0 {
			data, err := copyGlobalBytes(hMem, maxClipboardImageBytes)
			if err == nil && len(data) >= 8 && bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")) {
				return clipboardItem{kind: "image", image: data}, true, nil
			}
		}
	}
	if hasDIB {
		if hMem, _, _ := getClipboardData.Call(cfDIB); hMem != 0 {
			dib, err := copyGlobalBytes(hMem, maxDIBBytes)
			if err != nil {
				return clipboardItem{}, false, err
			}
			if len(dib) >= 40 {
				pngData, err := dibToPNG(dib)
				if err == nil && len(pngData) > 0 && len(pngData) <= maxClipboardImageBytes {
					return clipboardItem{kind: "image", image: pngData}, true, nil
				}
			}
		}
	}
	return clipboardItem{}, false, nil
}

func setClipboardText(text string) error {
	encoded := utf16.Encode([]rune(text))
	encoded = append(encoded, 0)
	byteLen := len(encoded) * 2
	hMem, _, err := globalAlloc.Call(gmemMoveable, uintptr(byteLen))
	if hMem == 0 {
		return fmt.Errorf("GlobalAlloc: %v", err)
	}
	dst, _, err := globalLock.Call(hMem)
	if dst == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("GlobalLock: %v", err)
	}
	rtlMoveMemory.Call(dst, uintptr(unsafe.Pointer(&encoded[0])), uintptr(byteLen))
	runtime.KeepAlive(encoded)
	globalUnlock.Call(hMem)

	if err := openClipboardWithRetry(); err != nil {
		globalFree.Call(hMem)
		return err
	}
	defer closeClipboard.Call()

	if ok, _, err := emptyClipboard.Call(); ok == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("EmptyClipboard: %v", err)
	}
	if res, _, err := setClipboardData.Call(cfUnicodeText, hMem); res == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("SetClipboardData: %v", err)
	}
	return nil
}

func setClipboardImage(pngData []byte) error {
	dib, err := pngToDIB(pngData)
	if err != nil {
		return err
	}
	hDIB, err := allocGlobalBytes(dib)
	if err != nil {
		return err
	}
	var hPNG uintptr
	pngFmt := pngClipboardFormat()
	if pngFmt != 0 {
		hPNG, err = allocGlobalBytes(pngData)
		if err != nil {
			globalFree.Call(hDIB)
			return err
		}
	}

	if err := openClipboardWithRetry(); err != nil {
		globalFree.Call(hDIB)
		if hPNG != 0 {
			globalFree.Call(hPNG)
		}
		return err
	}
	defer closeClipboard.Call()

	if ok, _, err := emptyClipboard.Call(); ok == 0 {
		globalFree.Call(hDIB)
		if hPNG != 0 {
			globalFree.Call(hPNG)
		}
		return fmt.Errorf("EmptyClipboard: %v", err)
	}
	if res, _, err := setClipboardData.Call(cfDIB, hDIB); res == 0 {
		globalFree.Call(hDIB)
		if hPNG != 0 {
			globalFree.Call(hPNG)
		}
		return fmt.Errorf("SetClipboardData(CF_DIB): %v", err)
	}
	// hDIB is now owned by Windows; never free it even if registering PNG fails.
	if hPNG != 0 {
		if res, _, _ := setClipboardData.Call(pngFmt, hPNG); res == 0 {
			globalFree.Call(hPNG)
		}
	}
	return nil
}

func setClipboardFiles(paths []string) error {
	var payload []uint16
	for _, p := range paths {
		clean := filepath.Clean(p)
		if clean == "" {
			continue
		}
		payload = append(payload, utf16.Encode([]rune(clean))...)
		payload = append(payload, 0)
	}
	if len(payload) == 0 {
		return nil
	}
	payload = append(payload, 0)
	raw := make([]byte, 20+len(payload)*2)
	binary.LittleEndian.PutUint32(raw[0:4], 20)
	binary.LittleEndian.PutUint32(raw[16:20], 1) // fWide = TRUE
	for idx, u := range payload {
		binary.LittleEndian.PutUint16(raw[20+idx*2:22+idx*2], u)
	}
	hMem, err := allocGlobalBytes(raw)
	if err != nil {
		return err
	}
	if err := openClipboardWithRetry(); err != nil {
		globalFree.Call(hMem)
		return err
	}
	defer closeClipboard.Call()
	if ok, _, err := emptyClipboard.Call(); ok == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("EmptyClipboard: %v", err)
	}
	if res, _, err := setClipboardData.Call(cfHDrop, hMem); res == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("SetClipboardData(CF_HDROP): %v", err)
	}
	return nil
}
