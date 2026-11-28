package main

import (
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

var user32 = syscall.NewLazyDLL("user32.dll")
var sendInput = user32.NewProc("SendInput")
var getCursorPos = user32.NewProc("GetCursorPos")
var setCursorPos = user32.NewProc("SetCursorPos")
var monitorFromRect = user32.NewProc("MonitorFromRect")
var getMonitorInfoW = user32.NewProc("GetMonitorInfoW")
var setThreadDPI = user32.NewProc("SetThreadDpiAwarenessContext")
var getForegroundWindow = user32.NewProc("GetForegroundWindow")
var getWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
var getKeyboardLayout = user32.NewProc("GetKeyboardLayout")

func currentKeyboardLayout() string {
	hwnd, _, _ := getForegroundWindow.Call()
	var tid uintptr
	if hwnd != 0 {
		tid, _, _ = getWindowThreadProcessId.Call(hwnd, 0)
	}
	hkl, _, _ := getKeyboardLayout.Call(tid)
	return layoutCodeFromHKL(hkl)
}

func setDPIAware() {
	user32.NewProc("SetProcessDPIAware").Call()
}

// Cursor coordinates must agree even when hosted by a DPI-unaware Python process.
func cursorDPI() func() {
	if setThreadDPI.Find() != nil {
		return func() {}
	}
	runtime.LockOSThread()
	previous, _, _ := setThreadDPI.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4.
	return func() {
		if previous != 0 {
			setThreadDPI.Call(previous)
		}
		runtime.UnlockOSThread()
	}
}

type winRect struct {
	left, top, right, bottom int32
}

type monitorInfo struct {
	size    uint32
	monitor winRect
	work    winRect
	flags   uint32
}

// nearBottomEdge reports whether (x, y) lies within margin pixels of the bottom edge of its
// monitor and no other Windows monitor lies directly below it. Caller must hold cursorDPI().
func nearBottomEdge(x, y, margin int32) (winRect, bool) {
	const (
		monitorDefaultToNull    = 0
		monitorDefaultToNearest = 2
	)
	probe := winRect{left: x, top: y, right: x + 1, bottom: y + 1}
	mon, _, _ := monitorFromRect.Call(uintptr(unsafe.Pointer(&probe)), monitorDefaultToNearest)
	if mon == 0 {
		return winRect{}, false
	}
	var mi monitorInfo
	mi.size = uint32(unsafe.Sizeof(mi))
	ok, _, _ := getMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
	if ok == 0 || y < mi.monitor.bottom-margin {
		return winRect{}, false
	}
	below := winRect{left: x, top: mi.monitor.bottom, right: x + 1, bottom: mi.monitor.bottom + 1}
	nextMon, _, _ := monitorFromRect.Call(uintptr(unsafe.Pointer(&below)), monitorDefaultToNull)
	if nextMon != 0 {
		return winRect{}, false
	}
	return mi.monitor, true
}

// pointAtBottom reports whether (x, y) rests on the bottom edge of its monitor
// and no other Windows monitor lies directly below it. Caller must hold cursorDPI().
func pointAtBottom(x, y int32) bool {
	_, ok := nearBottomEdge(x, y, 1)
	return ok
}

func atBottom() bool {
	defer cursorDPI()()
	var point [2]int32
	ok, _, _ := getCursorPos.Call(uintptr(unsafe.Pointer(&point)))
	if ok == 0 {
		return false
	}
	return pointAtBottom(point[0], point[1])
}

// The union is sized and aligned by MOUSEINPUT on 64-bit Windows.
type mouseInput struct {
	x, y              int32
	data, flags, time uint32
	extra             uintptr
}
type input struct {
	kind  uint32
	mouse mouseInput
}
type keyboardInput struct {
	virtualKey, scanCode uint16
	flags, time          uint32
	extra                uintptr
}

var mouseButtons = [3][2]uint32{{4, 2}, {16, 8}, {64, 32}}

func inject(i *input) error {
	count, _, err := sendInput.Call(1, uintptr(unsafe.Pointer(i)), unsafe.Sizeof(*i))
	if count != 1 {
		return fmt.Errorf("SendInput failed: %v", err)
	}
	return nil
}

func injectBatch(inputs []input) error {
	if len(inputs) == 0 {
		return nil
	}
	count, _, err := sendInput.Call(uintptr(len(inputs)), uintptr(unsafe.Pointer(&inputs[0])), unsafe.Sizeof(inputs[0]))
	if int(count) != len(inputs) {
		return fmt.Errorf("SendInput batch failed (%d/%d): %v", count, len(inputs), err)
	}
	return nil
}

func sendShortcut(action string) error {
	if action == "zoomIn" || action == "zoomOut" {
		wheel := int32(120)
		if action == "zoomOut" {
			wheel = -120
		}
		var ctrlDown input
		ctrlDown.kind = 1
		kd := (*keyboardInput)(unsafe.Pointer(&ctrlDown.mouse))
		kd.virtualKey = 0xA2
		kd.scanCode = 0x1D

		var wheelInput input
		wheelInput.mouse = mouseInput{data: uint32(wheel), flags: 0x0800}

		var ctrlUp input
		ctrlUp.kind = 1
		ku := (*keyboardInput)(unsafe.Pointer(&ctrlUp.mouse))
		ku.virtualKey = 0xA2
		ku.scanCode = 0x1D
		ku.flags = 2

		return injectBatch([]input{ctrlDown, wheelInput, ctrlUp})
	}
	keys, ok := shortcutCombo(action)
	if !ok {
		return nil
	}
	inputs := make([]input, 0, len(keys)*2)
	for _, sk := range keys {
		var entry input
		entry.kind = 1
		k := (*keyboardInput)(unsafe.Pointer(&entry.mouse))
		k.virtualKey = sk.vk
		k.scanCode = sk.scan
		if sk.extended {
			k.flags = 1
		}
		inputs = append(inputs, entry)
	}
	for idx := len(keys) - 1; idx >= 0; idx-- {
		sk := keys[idx]
		var entry input
		entry.kind = 1
		k := (*keyboardInput)(unsafe.Pointer(&entry.mouse))
		k.virtualKey = sk.vk
		k.scanCode = sk.scan
		k.flags = 2
		if sk.extended {
			k.flags |= 1
		}
		inputs = append(inputs, entry)
	}
	return injectBatch(inputs)
}

func moveCursor(x, y int32) error {
	ok, _, err := setCursorPos.Call(uintptr(x), uintptr(y))
	if ok == 0 {
		return fmt.Errorf("SetCursorPos failed: %v", err)
	}
	return nil
}

func (e event) send() error {
	i := input{}
	switch e.Kind {
	case "enter":
		defer cursorDPI()()
		var point [2]int32
		if ok, _, err := getCursorPos.Call(uintptr(unsafe.Pointer(&point))); ok == 0 {
			return fmt.Errorf("GetCursorPos failed: %v", err)
		}
		if pointAtBottom(point[0], point[1]) {
			return moveCursor(point[0], point[1]-4)
		}
		return nil
	case "move":
		i.mouse = mouseInput{x: e.X, y: e.Y, flags: 0x0001}
	case "scroll":
		if e.Y != 0 {
			i.mouse = mouseInput{data: uint32(e.Y), flags: 0x0800}
			if err := inject(&i); err != nil {
				return err
			}
		}
		if e.X == 0 {
			return nil
		}
		i.mouse = mouseInput{data: uint32(e.X), flags: 0x1000}
	case "button":
		index := 0
		if e.Down {
			index = 1
		}
		i.mouse.flags = mouseButtons[e.Code][index]
	case "key":
		i.kind = 1
		k := (*keyboardInput)(unsafe.Pointer(&i.mouse))
		k.scanCode = e.Code & 0xff
		k.flags = 8
		if e.Code&0x100 != 0 {
			k.flags |= 1
		}
		if !e.Down {
			k.flags |= 2
		}
	}
	return inject(&i)
}
