package main

import (
	"fmt"
	"log"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

var (
	gdi32                       = syscall.NewLazyDLL("gdi32.dll")
	createSolidBrush            = gdi32.NewProc("CreateSolidBrush")
	deleteObject                = gdi32.NewProc("DeleteObject")
	setBkMode                   = gdi32.NewProc("SetBkMode")
	setTextColor                = gdi32.NewProc("SetTextColor")
	registerClassExW            = user32.NewProc("RegisterClassExW")
	createWindowExW             = user32.NewProc("CreateWindowExW")
	showWindow                  = user32.NewProc("ShowWindow")
	destroyWindow               = user32.NewProc("DestroyWindow")
	defWindowProcW              = user32.NewProc("DefWindowProcW")
	getMessageW                 = user32.NewProc("GetMessageW")
	translateMessage            = user32.NewProc("TranslateMessage")
	dispatchMessageW            = user32.NewProc("DispatchMessageW")
	postQuitMessage             = user32.NewProc("PostQuitMessage")
	invalidateRect              = user32.NewProc("InvalidateRect")
	beginPaint                  = user32.NewProc("BeginPaint")
	endPaint                    = user32.NewProc("EndPaint")
	loadCursorW                 = user32.NewProc("LoadCursorW")
	fillRect                    = user32.NewProc("FillRect")
	frameRect                   = user32.NewProc("FrameRect")
	drawTextW                   = user32.NewProc("DrawTextW")
	getModuleHandleW            = kernel32.NewProc("GetModuleHandleW")
	dragFinish                  = shell32Clip.NewProc("DragFinish")
	getAsyncKeyState            = user32.NewProc("GetAsyncKeyState")
	setWindowPos                = user32.NewProc("SetWindowPos")
	setTimer                    = user32.NewProc("SetTimer")
	killTimer                   = user32.NewProc("KillTimer")
	postMessageW                = user32.NewProc("PostMessageW")
	changeWindowMessageFilterEx = user32.NewProc("ChangeWindowMessageFilterEx")
	getClientRect               = user32.NewProc("GetClientRect")
)

type wndClassExW struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  uintptr
	lpszClassName uintptr
	hIconSm       uintptr
}

type paintStruct struct {
	hdc        uintptr
	fErase     int32
	rcPaint    winRect
	fRestore   int32
	fIncUpdate int32
	reserved   [32]byte
}

type winMsg struct {
	hwnd     uintptr
	message  uint32
	wParam   uintptr
	lParam   uintptr
	time     uint32
	pt       [2]int32
	lPrivate uint32
}

func drawTextLine(hdc uintptr, text string, rc *winRect) {
	u16, err := syscall.UTF16FromString(text)
	if err != nil {
		return
	}
	setBkMode.Call(hdc, 1) // TRANSPARENT
	setTextColor.Call(hdc, 0x00FFFFFF)
	drawTextW.Call(hdc, uintptr(unsafe.Pointer(&u16[0])), uintptr(len(u16)-1), uintptr(unsafe.Pointer(rc)), 0x0825) // DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX
}

type dropBarSession struct {
	hwnd          uintptr
	onDrop        func([]string)
	hBgBrush      uintptr
	hBorderBrush  uintptr
	hSuccessBrush uintptr
	wasLMBDown    bool
	dragArmed     bool
	visible       bool
	releaseAt     time.Time
	statusText    string
	statusUntil   time.Time
}

var (
	dropBarClassOnce sync.Once
	dropBarClassErr  error
	currentDropBar   *dropBarSession
	dropBarMu        sync.Mutex
	dropBarProcPtr   = syscall.NewCallback(dropBarWndProc)
)

func ensureDropBarClass(hInst uintptr) error {
	dropBarClassOnce.Do(func() {
		name, err := syscall.UTF16PtrFromString("PriloDropBar")
		if err != nil {
			dropBarClassErr = err
			return
		}
		cursor, _, _ := loadCursorW.Call(0, 32512) // IDC_ARROW
		wc := wndClassExW{
			cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
			style:         0x0003,
			lpfnWndProc:   dropBarProcPtr,
			hInstance:     hInst,
			hCursor:       cursor,
			lpszClassName: uintptr(unsafe.Pointer(name)),
		}
		atom, _, regErr := registerClassExW.Call(uintptr(unsafe.Pointer(&wc)))
		if atom == 0 {
			dropBarClassErr = fmt.Errorf("RegisterClassExW(PriloDropBar): %v", regErr)
		}
	})
	return dropBarClassErr
}

func startDropBar(onDrop func([]string)) func() {
	ready := make(chan uintptr, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		runtime.LockOSThread()
		defer cursorDPI()()

		hInst, _, _ := getModuleHandleW.Call(0)
		if err := ensureDropBarClass(hInst); err != nil {
			log.Printf("drop bar class: %v", err)
			ready <- 0
			return
		}
		hBgBrush, _, _ := createSolidBrush.Call(0x00342218)      // dark slate RGB(24, 34, 52)
		hBorderBrush, _, _ := createSolidBrush.Call(0x00F6823B)  // blue RGB(59, 130, 246)
		hSuccessBrush, _, _ := createSolidBrush.Call(0x005EC522) // green RGB(34, 197, 94)
		defer deleteObject.Call(hBgBrush)
		defer deleteObject.Call(hBorderBrush)
		defer deleteObject.Call(hSuccessBrush)

		sess := &dropBarSession{
			onDrop:        onDrop,
			hBgBrush:      hBgBrush,
			hBorderBrush:  hBorderBrush,
			hSuccessBrush: hSuccessBrush,
		}
		dropBarMu.Lock()
		currentDropBar = sess
		dropBarMu.Unlock()
		defer func() {
			dropBarMu.Lock()
			if currentDropBar == sess {
				currentDropBar = nil
			}
			dropBarMu.Unlock()
		}()

		className, _ := syscall.UTF16PtrFromString("PriloDropBar")
		winTitle, _ := syscall.UTF16PtrFromString("Fuso Drop")
		const (
			wsExTopmost     = 0x00000008
			wsExToolWindow  = 0x00000080
			wsExAcceptFiles = 0x00000010
			wsPopup         = 0x80000000
		)
		hwnd, _, err := createWindowExW.Call(
			wsExTopmost|wsExToolWindow|wsExAcceptFiles,
			uintptr(unsafe.Pointer(className)),
			uintptr(unsafe.Pointer(winTitle)),
			wsPopup,
			0, 0, 360, 48,
			0, 0, hInst, 0,
		)
		if hwnd == 0 {
			log.Printf("drop bar CreateWindowExW: %v", err)
			ready <- 0
			return
		}
		sess.hwnd = hwnd
		if changeWindowMessageFilterEx.Find() == nil {
			for _, msgID := range []uintptr{0x0233, 0x004A, 0x0049} {
				changeWindowMessageFilterEx.Call(hwnd, msgID, 1, 0)
			}
		}
		setTimer.Call(hwnd, 1, 60, 0)
		ready <- hwnd

		var msg winMsg
		for {
			ret, _, _ := getMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
			if int32(ret) <= 0 {
				break
			}
			translateMessage.Call(uintptr(unsafe.Pointer(&msg)))
			dispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
		}
	}()

	hwnd := <-ready
	var once sync.Once
	return func() {
		once.Do(func() {
			if hwnd != 0 {
				postMessageW.Call(hwnd, 0x0010, 0, 0) // WM_CLOSE
			}
			<-done
		})
	}
}

func (s *dropBarSession) pollDragState() {
	if !s.statusUntil.IsZero() {
		if time.Now().Before(s.statusUntil) {
			return
		}
		s.statusUntil = time.Time{}
		s.statusText = ""
		showWindow.Call(s.hwnd, 0) // SW_HIDE
		s.visible = false
		return
	}

	state, _, _ := getAsyncKeyState.Call(0x01) // VK_LBUTTON
	lmbDown := (state & 0x8000) != 0

	var pt [2]int32
	if ok, _, _ := getCursorPos.Call(uintptr(unsafe.Pointer(&pt))); ok == 0 {
		return
	}
	if lmbDown && !s.wasLMBDown {
		_, nearStart := nearBottomEdge(pt[0], pt[1], 56)
		s.dragArmed = !nearStart
		s.releaseAt = time.Time{}
	}
	s.wasLMBDown = lmbDown

	if lmbDown && s.dragArmed {
		if mon, near := nearBottomEdge(pt[0], pt[1], 36); near {
			if !s.visible {
				const barW, barH int32 = 360, 48
				x := pt[0] - barW/2
				if x < mon.left+8 {
					x = mon.left + 8
				}
				if x+barW > mon.right-8 {
					x = mon.right - barW - 8
				}
				y := mon.bottom - barH
				const (
					hwndTopmost   = ^uintptr(0) // -1
					swpNoActivate = 0x0010
					swpShowWindow = 0x0040
				)
				setWindowPos.Call(s.hwnd, hwndTopmost, uintptr(x), uintptr(y), uintptr(barW), uintptr(barH), swpNoActivate|swpShowWindow)
				invalidateRect.Call(s.hwnd, 0, 0)
				s.visible = true
			}
			s.releaseAt = time.Time{}
		} else if s.visible {
			if _, stillNear := nearBottomEdge(pt[0], pt[1], 120); !stillNear {
				showWindow.Call(s.hwnd, 0) // SW_HIDE
				s.visible = false
			}
		}
		return
	}

	s.dragArmed = false
	if s.visible {
		if s.releaseAt.IsZero() {
			s.releaseAt = time.Now()
		} else if time.Since(s.releaseAt) >= 250*time.Millisecond {
			showWindow.Call(s.hwnd, 0)
			s.visible = false
			s.releaseAt = time.Time{}
		}
	}
}

func dropBarWndProc(hwnd, msg, wParam, lParam uintptr) uintptr {
	dropBarMu.Lock()
	sess := currentDropBar
	dropBarMu.Unlock()
	if sess == nil {
		r, _, _ := defWindowProcW.Call(hwnd, msg, wParam, lParam)
		return r
	}
	switch msg {
	case 0x0113: // WM_TIMER
		sess.pollDragState()
		return 0
	case 0x0014: // WM_ERASEBKGND
		return 1
	case 0x000F: // WM_PAINT
		var ps paintStruct
		hdc, _, _ := beginPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
		if hdc != 0 {
			var rc winRect
			getClientRect.Call(hwnd, uintptr(unsafe.Pointer(&rc)))
			fillRect.Call(hdc, uintptr(unsafe.Pointer(&rc)), sess.hBgBrush)
			if !sess.statusUntil.IsZero() && time.Now().Before(sess.statusUntil) {
				frameRect.Call(hdc, uintptr(unsafe.Pointer(&rc)), sess.hSuccessBrush)
				drawTextLine(hdc, sess.statusText, &rc)
			} else {
				frameRect.Call(hdc, uintptr(unsafe.Pointer(&rc)), sess.hBorderBrush)
				drawTextLine(hdc, "↓ Отпустите файлы для отправки на Mac (Загрузки)", &rc)
			}
			endPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
		}
		return 0
	case 0x0233: // WM_DROPFILES
		hDrop := wParam
		count, _, _ := dragQueryFileW.Call(hDrop, 0xFFFFFFFF, 0, 0)
		if count > maxClipboardFileCount {
			count = maxClipboardFileCount
		}
		paths := make([]string, 0, int(count))
		for i := uintptr(0); i < count; i++ {
			chars, _, _ := dragQueryFileW.Call(hDrop, i, 0, 0)
			if chars == 0 || chars > 32767 {
				continue
			}
			buf := make([]uint16, int(chars)+1)
			copied, _, _ := dragQueryFileW.Call(hDrop, i, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
			if copied > 0 {
				paths = append(paths, syscall.UTF16ToString(buf[:copied]))
			}
		}
		dragFinish.Call(hDrop)
		sess.dragArmed = false
		sess.releaseAt = time.Time{}
		if len(paths) > 0 && sess.onDrop != nil {
			if len(paths) == 1 {
				sess.statusText = "✓ Отправлено на Mac в «Загрузки»"
			} else {
				sess.statusText = fmt.Sprintf("✓ Отправлено на Mac в «Загрузки» (%d)", len(paths))
			}
			sess.statusUntil = time.Now().Add(1800 * time.Millisecond)
			invalidateRect.Call(hwnd, 0, 0)
			go sess.onDrop(paths)
		} else {
			showWindow.Call(hwnd, 0)
			sess.visible = false
		}
		return 0
	case 0x0010: // WM_CLOSE
		killTimer.Call(hwnd, 1)
		destroyWindow.Call(hwnd)
		return 0
	case 0x0002: // WM_DESTROY
		postQuitMessage.Call(0)
		return 0
	}
	r, _, _ := defWindowProcW.Call(hwnd, msg, wParam, lParam)
	return r
}
