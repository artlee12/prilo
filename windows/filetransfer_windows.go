package main

import (
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

type guid struct {
	Data1 uint32
	Data2 uint16
	Data3 uint16
	Data4 [8]byte
}

var (
	ole32                = syscall.NewLazyDLL("ole32.dll")
	coTaskMemFree        = ole32.NewProc("CoTaskMemFree")
	shGetKnownFolderPath = shell32Clip.NewProc("SHGetKnownFolderPath")
	lstrlenW             = kernel32.NewProc("lstrlenW")
	folderIDDownloads    = guid{0x374DE290, 0x123F, 0x4565, [8]byte{0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B}}
	folderIDDesktop      = guid{0xB4BFCC3A, 0xDB2C, 0x424C, [8]byte{0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41}}
)

func knownFolderPath(id guid) string {
	var ptr uintptr
	hr, _, _ := shGetKnownFolderPath.Call(
		uintptr(unsafe.Pointer(&id)),
		0,
		0,
		uintptr(unsafe.Pointer(&ptr)),
	)
	if hr != 0 || ptr == 0 {
		return ""
	}
	defer coTaskMemFree.Call(ptr)
	n, _, _ := lstrlenW.Call(ptr)
	if n == 0 || n > 32768 {
		return ""
	}
	buf := make([]uint16, int(n))
	rtlMoveMemory.Call(uintptr(unsafe.Pointer(&buf[0])), ptr, uintptr(n*2))
	runtime.KeepAlive(buf)
	return syscall.UTF16ToString(buf)
}

func resolveFileDestination(dest string) (string, error) {
	switch dest {
	case "clipboard":
		return filepath.Join(os.TempDir(), "Prilo", "Clipboard"), nil
	case "desktop":
		if p := knownFolderPath(folderIDDesktop); p != "" {
			return p, nil
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, "Desktop"), nil
	default:
		if p := knownFolderPath(folderIDDownloads); p != "" {
			return p, nil
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, "Downloads"), nil
	}
}
