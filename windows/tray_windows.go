package main

import (
	_ "embed"
	"errors"
	"log"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"fyne.io/systray"
)

//go:embed prilo.ico
var trayIcon []byte

var messageBox = user32.NewProc("MessageBoxW")

const (
	mbIconError       = 0x10
	mbIconInformation = 0x40
	mbSetForeground   = 0x10000
	mbTopMost         = 0x40000
)

func showMessageResult(text string, flags uintptr) uintptr {
	title, _ := syscall.UTF16PtrFromString("Fuso Receiver")
	body, err := syscall.UTF16PtrFromString(text)
	if err != nil {
		return 0
	}
	result, _, _ := messageBox.Call(0, uintptr(unsafe.Pointer(body)), uintptr(unsafe.Pointer(title)), flags|mbSetForeground|mbTopMost)
	return result
}

func showMessage(text string, flags uintptr) { showMessageResult(text, flags) }

func showInfo(text string)  { showMessage(text, mbIconInformation) }
func showError(text string) { showMessage(text, mbIconError) }

type trayApp struct {
	invite  *pairingInvite
	details func() string
	quit    func()
}

func (a *trayApp) pairingText(fresh bool) string {
	code, ok := a.invite.current(time.Now())
	if fresh || !ok {
		var err error
		if code, err = a.invite.issue(); err != nil {
			log.Printf("Pairing code: %v", err)
			return "Не удалось создать код сопряжения. Подробности в журнале."
		}
	}
	return "Код сопряжения Fuso:\n\n" + code +
		"\n\nНа Mac нажми «Найти ПК в сети», выбери этот ПК и вставь код. Код действует 10 минут и работает один раз.\n\nCtrl+C копирует текст этого окна."
}

// runTray shows the tray icon and blocks until the user quits.
func runTray(app *trayApp) {
	systray.Run(func() {
		systray.SetIcon(trayIcon)
		systray.SetTooltip("Fuso Receiver")
		status := systray.AddMenuItem("Fuso Receiver работает", "")
		status.Disable()
		systray.AddSeparator()
		pair := systray.AddMenuItem("Код сопряжения…", "Показать одноразовый код для Mac")
		fresh := systray.AddMenuItem("Новый код сопряжения", "Заменить код сопряжения")
		details := systray.AddMenuItem("Данные для ручного подключения…", "IP, код доступа и отпечаток")
		systray.AddSeparator()
		startup := systray.AddMenuItemCheckbox("Запускать при входе в Windows", "", autostartEnabled())
		firewall := systray.AddMenuItem("Разрешить в брандмауэре…", "Открыть порт 43821 для Mac в частной сети")
		logs := systray.AddMenuItem("Открыть журнал", "")
		updates := systray.AddMenuItem("Проверить обновления…", "Версия "+version)
		pipCmd := systray.AddMenuItem("Скопировать команду обновления (cmd)…", "Скопировать pip install --upgrade prilo-receiver")
		systray.AddSeparator()
		quit := systray.AddMenuItem("Выйти из Fuso", "Остановить приёмник")

		var updating sync.Mutex
		update := func(quiet bool) {
			if !updating.TryLock() {
				return
			}
			defer updating.Unlock()
			if path, ok := checkForUpdate(quiet); ok {
				app.quit()
				if err := restartUpdated(path); err != nil {
					log.Printf("Restart after update: %v", err)
					showError("Обновление установлено. Запусти Fuso Receiver заново.")
				}
				systray.Quit()
			}
		}
		go func() {
			time.Sleep(time.Minute)
			for {
				update(true)
				time.Sleep(24 * time.Hour)
			}
		}()
		if launchedAfterUpdate {
			go showInfo("Fuso Receiver обновлён до версии " + version + ".")
		} else if !launchedAtLogin {
			go showInfo("Fuso Receiver работает в фоне. Значок в трее открывает меню.\n\n" + app.pairingText(false) +
				"\n\nЕсли Mac находит ПК, но не подключается, выбери в меню «Разрешить в брандмауэре…».")
		}
		go func() {
			for {
				select {
				case <-pair.ClickedCh:
					go showInfo(app.pairingText(false))
				case <-fresh.ClickedCh:
					go showInfo(app.pairingText(true))
				case <-details.ClickedCh:
					go showInfo(app.details() + "\nCtrl+C копирует текст этого окна.")
				case <-startup.ClickedCh:
					enable := !startup.Checked()
					if err := setAutostart(enable); err != nil {
						log.Printf("Autostart: %v", err)
						go showError("Не удалось изменить автозапуск. Подробности в журнале.")
					}
					if autostartEnabled() {
						startup.Check()
					} else {
						startup.Uncheck()
					}
				case <-firewall.ClickedCh:
					go func() {
						err := allowFirewall()
						switch {
						case err == nil:
							log.Print("Firewall rule updated")
							showInfo("Брандмауэр Windows разрешает Fuso входящие подключения в частных сетях. Попробуй подключиться с Mac.\n\nЕсли Mac всё ещё не подключается, проверь, что сеть Windows отмечена как «Частная»: Параметры → Сеть и Интернет → свойства сети.")
						case errors.Is(err, errElevationDeclined):
						default:
							log.Printf("Firewall: %v", err)
							showError("Не удалось изменить правило брандмауэра. Подробности в журнале.")
						}
					}()
				case <-updates.ClickedCh:
					go update(false)
				case <-pipCmd.ClickedCh:
					const cmdText = "python -m pip install --upgrade --no-cache-dir --index-url https://pypi.org/simple prilo-receiver"
					if err := setClipboardText(cmdText); err != nil {
						log.Printf("Copy pip command: %v", err)
					}
					go showInfo("Команда обновления скопирована в буфер обмена:\n\n" + cmdText + "\n\nОстанови приёмник (Ctrl+C) и вставь её в cmd.")
				case <-logs.ClickedCh:
					if err := openPath(logPath()); err != nil {
						go showError("Журнал пока не создан.")
					}
				case <-quit.ClickedCh:
					app.quit()
					systray.Quit()
					return
				}
			}
		}()
	}, nil)
}

var shellExecute = syscall.NewLazyDLL("shell32.dll").NewProc("ShellExecuteW")

func openPath(path string) error {
	verb, _ := syscall.UTF16PtrFromString("open")
	target, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if result, _, _ := shellExecute.Call(0, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(target)), 0, 0, 1); result <= 32 {
		return syscall.Errno(result)
	}
	return nil
}
