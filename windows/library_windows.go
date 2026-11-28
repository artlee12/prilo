//go:build prilo_library

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"sync"
	"time"
	"unsafe"
)

var hosted struct {
	sync.Mutex
	service *receiverService
}

type libraryResponse struct {
	Code    string `json:"code,omitempty"`
	Details string `json:"details,omitempty"`
	Version string `json:"version,omitempty"`
	Error   string `json:"error,omitempty"`
}

func (result libraryResponse) encode() *C.char {
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}

func libraryResult(code string, err string) *C.char {
	return (libraryResponse{Code: code, Error: err}).encode()
}

//export PriloStart
func PriloStart() *C.char {
	hosted.Lock()
	defer hosted.Unlock()
	if hosted.service != nil {
		select {
		case <-hosted.service.done:
			hosted.service.close()
			hosted.service = nil
		default:
			return libraryResult("", "Fuso Receiver is already running in this process.")
		}
	}
	service, err := startReceiver(nil)
	if err != nil {
		return libraryResult("", err.Error())
	}
	code, ok := service.invite.current(time.Now())
	if !ok {
		service.close()
		return libraryResult("", "Could not create the Fuso pairing code.")
	}
	hosted.service = service
	return (libraryResponse{Code: code, Version: version}).encode()
}

//export PriloNewPairingCode
func PriloNewPairingCode() *C.char {
	hosted.Lock()
	defer hosted.Unlock()
	if hosted.service == nil {
		return libraryResult("", "Fuso Receiver is not running.")
	}
	select {
	case <-hosted.service.done:
		return libraryResult("", "Fuso Receiver has stopped.")
	default:
	}
	code, err := hosted.service.invite.issue()
	if err != nil {
		return libraryResult("", err.Error())
	}
	return libraryResult(code, "")
}

//export PriloConnectionDetails
func PriloConnectionDetails() *C.char {
	hosted.Lock()
	defer hosted.Unlock()
	if hosted.service == nil {
		return libraryResult("", "Fuso Receiver is not running.")
	}
	select {
	case <-hosted.service.done:
		return libraryResult("", "Fuso Receiver has stopped.")
	default:
		return (libraryResponse{Details: hosted.service.details()}).encode()
	}
}

//export PriloStop
func PriloStop() {
	hosted.Lock()
	defer hosted.Unlock()
	if hosted.service != nil {
		hosted.service.close()
		hosted.service = nil
	}
}

//export PriloFree
func PriloFree(pointer unsafe.Pointer) {
	C.free(pointer)
}
