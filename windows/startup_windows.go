package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

// launchedAtLogin is true when Windows started the receiver from the Run key.
var launchedAtLogin bool

// launchedAfterUpdate is true when the previous copy restarted into this one.
var launchedAfterUpdate bool

func regExe() (string, error) {
	root := os.Getenv("SystemRoot")
	if !filepath.IsAbs(root) {
		return "", fmt.Errorf("Windows system directory is unavailable")
	}
	return filepath.Join(root, "System32", "reg.exe"), nil
}

func hiddenCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return cmd
}

// autostartEnabled reports whether this Windows account starts the receiver at sign-in.
func autostartEnabled() bool {
	reg, err := regExe()
	if err != nil {
		return false
	}
	return hiddenCommand(reg, "query", runKey, "/v", "PriloReceiver").Run() == nil
}

// setAutostart adds or removes this executable from the account's Run key.
func setAutostart(enable bool) error {
	reg, err := regExe()
	if err != nil {
		return err
	}
	args := []string{"delete", runKey, "/v", "PriloReceiver", "/f"}
	if enable {
		path, err := os.Executable()
		if err != nil {
			return err
		}
		args = []string{"add", runKey, "/v", "PriloReceiver", "/t", "REG_SZ", "/d", `"` + path + `" --autostart`, "/f"}
	} else if !autostartEnabled() {
		return nil
	}
	if output, err := hiddenCommand(reg, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("cannot update startup: %w (%s)", err, output)
	}
	return nil
}

// shellExecuteInfo mirrors SHELLEXECUTEINFOW; Go inserts the same padding as C on 64-bit Windows.
type shellExecuteInfo struct {
	size       uint32
	mask       uint32
	hwnd       uintptr
	verb       *uint16
	file       *uint16
	parameters *uint16
	directory  *uint16
	show       int32
	instApp    uintptr
	idList     uintptr
	class      *uint16
	keyClass   uintptr
	hotKey     uint32
	iconOrMon  uintptr
	process    syscall.Handle
}

var shellExecuteEx = syscall.NewLazyDLL("shell32.dll").NewProc("ShellExecuteExW")

// errElevationDeclined means the user closed the administrator prompt.
var errElevationDeclined = fmt.Errorf("administrator prompt was declined")

// runElevated runs a program with an administrator prompt and waits for its exit code.
func runElevated(program, parameters string) (uint32, error) {
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, err := syscall.UTF16PtrFromString(program)
	if err != nil {
		return 0, err
	}
	params, err := syscall.UTF16PtrFromString(parameters)
	if err != nil {
		return 0, err
	}
	const seeMaskNoCloseProcess = 0x40
	info := shellExecuteInfo{mask: seeMaskNoCloseProcess, verb: verb, file: file, parameters: params}
	info.size = uint32(unsafe.Sizeof(info))
	if ok, _, err := shellExecuteEx.Call(uintptr(unsafe.Pointer(&info))); ok == 0 {
		if errno, isErrno := err.(syscall.Errno); isErrno && errno == 1223 { // ERROR_CANCELLED
			return 0, errElevationDeclined
		}
		return 0, err
	}
	if info.process == 0 {
		return 0, fmt.Errorf("no process handle")
	}
	defer syscall.CloseHandle(info.process)
	if _, err := syscall.WaitForSingleObject(info.process, 60000); err != nil {
		return 0, err
	}
	var code uint32
	if err := syscall.GetExitCodeProcess(info.process, &code); err != nil {
		return 0, err
	}
	return code, nil
}

// allowFirewall replaces the inbound Windows Firewall rule for this executable on TCP 43821.
// Bonjour discovery can pass while the port is blocked, so the Mac may see the PC but time out.
func allowFirewall() error {
	path, err := os.Executable()
	if err != nil {
		return err
	}
	root := os.Getenv("SystemRoot")
	if !filepath.IsAbs(root) {
		return fmt.Errorf("Windows system directory is unavailable")
	}
	netsh := filepath.Join(root, "System32", "netsh.exe")
	cmd := filepath.Join(root, "System32", "cmd.exe")
	// cmd strips the outer quotes after /c; both netsh calls run in one elevated window.
	script := fmt.Sprintf(`/c ""%[1]s" advfirewall firewall delete rule name="Prilo Receiver" >nul 2>&1 & "%[1]s" advfirewall firewall add rule name="Prilo Receiver" dir=in action=allow enable=yes profile=private,domain protocol=TCP localport=43821 program="%[2]s""`, netsh, path)
	code, err := runElevated(cmd, script)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("netsh exited with %d", code)
	}
	return nil
}

func startupOption() (bool, error) {
	if len(os.Args) <= 1 {
		return false, nil
	}
	switch os.Args[1] {
	case "--autostart":
		launchedAtLogin = true
		return false, nil
	case "--updated":
		launchedAfterUpdate = true
		return false, nil
	case "--enable-autostart", "--disable-autostart":
		enable := os.Args[1] == "--enable-autostart"
		if err := setAutostart(enable); err != nil {
			return true, err
		}
		if enable {
			showInfo("Fuso Receiver будет запускаться в фоне после входа в этот аккаунт Windows. Значок появится в трее.")
		} else {
			showInfo("Автозапуск Fuso Receiver выключен.")
		}
		return true, nil
	default:
		return true, fmt.Errorf("unknown argument: %s", os.Args[1])
	}
}
