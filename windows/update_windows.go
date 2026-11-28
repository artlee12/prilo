package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

var messageBoxYesNo uintptr = 0x4 // MB_YESNO

const idYes = 6

func askYesNo(text string) bool {
	return showMessageResult(text, mbIconInformation|messageBoxYesNo) == idYes
}

// cleanupOldExe removes the copy left behind by the previous self-update.
func cleanupOldExe() {
	if path, err := os.Executable(); err == nil {
		os.Remove(path + ".old")
	}
}

// checkForUpdate asks GitHub for a newer receiver and, if the user agrees, installs it.
// It returns the path of the replaced exe when this process must restart into it.
func checkForUpdate(quiet bool) (string, bool) {
	latest, err := latestRelease("https://api.github.com", updateRepo)
	if err != nil {
		log.Printf("Update check: %v", err)
		if !quiet {
			showError("Не удалось проверить обновления. Проверь интернет и повтори.")
		}
		return "", false
	}
	asset, found := latest.asset(receiverAsset(runtime.GOARCH))
	if latest.Tag == "" || !found || !newerVersion(version, latest.Tag) {
		log.Printf("Update check: current %s, latest %q", version, latest.Tag)
		if !quiet {
			showInfo(fmt.Sprintf("Установлена последняя версия Prilo Receiver (%s).", version))
		}
		return "", false
	}
	if !askYesNo(fmt.Sprintf("Доступна новая версия Prilo Receiver: %s (сейчас %s).\n\nСкачать и перезапустить приёмник?", latest.Tag, version)) {
		return "", false
	}
	path, err := installUpdate(asset)
	if err != nil {
		log.Printf("Update install: %v", err)
		showError("Не удалось установить обновление. Подробности в журнале. Новую версию можно скачать вручную:\n" + latest.Page)
		return "", false
	}
	log.Printf("Updated to %s", latest.Tag)
	return path, true
}

// installUpdate downloads the new exe next to the running one and swaps the files.
// Windows lets a running exe be renamed but not overwritten.
// os.Executable is read first: after the rename it would name the .old file.
func installUpdate(asset releaseAsset) (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	base := strings.ToLower(filepath.Base(path))
	if strings.HasPrefix(base, "python") {
		return "", fmt.Errorf("hosted inside Python; update via pip")
	}
	fresh, old := path+".new", path+".old"
	if err := download(asset, fresh); err != nil {
		return "", err
	}
	os.Remove(old)
	if err := os.Rename(path, old); err != nil {
		os.Remove(fresh)
		return "", err
	}
	if err := os.Rename(fresh, path); err != nil {
		os.Rename(old, path)
		return "", err
	}
	return path, nil
}

// restartUpdated starts the replaced exe; with --updated it waits for the port this process frees.
func restartUpdated(path string) error {
	return hiddenCommand(path, "--updated").Start()
}
