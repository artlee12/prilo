package main

import (
	"fmt"
	"syscall"
)

const (
	esSystemRequired  uintptr = 0x00000001
	esDisplayRequired uintptr = 0x00000002
)

var (
	lockWorkStation         = user32.NewProc("LockWorkStation")
	setThreadExecutionState = kernel32.NewProc("SetThreadExecutionState")
)

func lockWindows() error {
	if ok, _, err := lockWorkStation.Call(); ok == 0 {
		if err != nil && err != syscall.Errno(0) {
			return fmt.Errorf("LockWorkStation: %w", err)
		}
		return fmt.Errorf("LockWorkStation failed")
	}
	return nil
}

// pulseKeepAwake resets Windows idle display/system timers without thread-affine ES_CONTINUOUS.
func pulseKeepAwake() {
	setThreadExecutionState.Call(esSystemRequired | esDisplayRequired)
}
