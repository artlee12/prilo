package main

import "fmt"

type shortcutKey struct {
	vk       uint16
	scan     uint16
	extended bool
}

var shortcutCombos = map[string][]shortcutKey{
	"desktopNext": {
		{vk: 0xA2, scan: 0x1D},                 // LCtrl
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x27, scan: 0x4D, extended: true}, // Right
	},
	"desktopPrev": {
		{vk: 0xA2, scan: 0x1D},                 // LCtrl
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x25, scan: 0x4B, extended: true}, // Left
	},
	"taskView": {
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x09, scan: 0x0F},                 // Tab
	},
	"showDesktop": {
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x44, scan: 0x20},                 // D
	},
	"switchAppNext": {
		{vk: 0xA4, scan: 0x38}, // LAlt
		{vk: 0x09, scan: 0x0F}, // Tab
	},
	"switchAppPrev": {
		{vk: 0xA4, scan: 0x38}, // LAlt
		{vk: 0xA0, scan: 0x2A}, // LShift
		{vk: 0x09, scan: 0x0F}, // Tab
	},
	"browserForward": {
		{vk: 0xA4, scan: 0x38},                 // LAlt
		{vk: 0x27, scan: 0x4D, extended: true}, // Right
	},
	"browserBack": {
		{vk: 0xA4, scan: 0x38},                 // LAlt
		{vk: 0x25, scan: 0x4B, extended: true}, // Left
	},
	"snip": {
		{vk: 0x2C, scan: 0x37, extended: true}, // Print Screen (VK_SNAPSHOT)
	},
}

func shortcutCombo(action string) ([]shortcutKey, bool) {
	keys, ok := shortcutCombos[action]
	return keys, ok
}

func validShortcutAction(action string) bool {
	if action == "zoomIn" || action == "zoomOut" {
		return true
	}
	_, ok := shortcutCombos[action]
	return ok
}

var primaryLangNames = map[uint16]string{
	0x19: "RU",
	0x09: "EN",
	0x22: "UA",
	0x23: "BY",
	0x3F: "KZ",
	0x07: "DE",
	0x0C: "FR",
	0x0A: "ES",
	0x10: "IT",
	0x15: "PL",
	0x1F: "TR",
	0x04: "ZH",
	0x11: "JA",
	0x12: "KO",
	0x0D: "HE",
	0x2B: "HY",
	0x37: "KA",
}

func layoutCodeFromHKL(hkl uintptr) string {
	if hkl == 0 {
		return ""
	}
	langID := uint16(hkl & 0xFFFF)
	if langID == 0 {
		return ""
	}
	if name, ok := primaryLangNames[langID&0x03FF]; ok {
		return name
	}
	return fmt.Sprintf("%04X", langID)
}
