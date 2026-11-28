package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

// openHappLink passes a happ:// link to the handler Happ registered with Windows.
func openHappLink(link string) error {
	verb, err := syscall.UTF16PtrFromString("open")
	if err != nil {
		return err
	}
	target, err := syscall.UTF16PtrFromString(link)
	if err != nil {
		return err
	}
	const showNoActivate = 4
	result, _, _ := shellExecute.Call(0, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(target)), 0, 0, showNoActivate)
	switch result {
	case 2, 3, 31: // file or path not found, no association
		return errHappMissing
	}
	if result <= 32 {
		return fmt.Errorf("ShellExecute returned %d", result)
	}
	return nil
}
