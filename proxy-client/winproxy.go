//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows/registry"
)

type winProxyBackup struct {
	enabled  uint32
	server   string
	override string
	active   bool
}

func parseListenHostPort(listen string) (host, port string, err error) {
	listen = stringsTrim(listen)
	if listen == "" {
		return "127.0.0.1", "1080", nil
	}
	if strings.HasPrefix(listen, "[") {
		if i := strings.LastIndex(listen, "]:"); i >= 0 {
			return listen[1:i], listen[i+2:], nil
		}
	}
	if i := strings.LastIndex(listen, ":"); i >= 0 {
		return listen[:i], listen[i+1:], nil
	}
	return listen, "1080", nil
}

func readWinProxyBackup() (winProxyBackup, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.QUERY_VALUE)
	if err != nil {
		return winProxyBackup{}, err
	}
	defer key.Close()

	enabled, _, err := key.GetIntegerValue("ProxyEnable")
	if err != nil {
		enabled = 0
	}
	server, _, err := key.GetStringValue("ProxyServer")
	if err != nil {
		server = ""
	}
	override, _, err := key.GetStringValue("ProxyOverride")
	if err != nil {
		override = ""
	}
	return winProxyBackup{
		enabled:  uint32(enabled),
		server:   server,
		override: override,
	}, nil
}

func applyWinProxy(listen string) (winProxyBackup, error) {
	host, port, err := parseListenHostPort(listen)
	if err != nil {
		return winProxyBackup{}, err
	}

	backup, err := readWinProxyBackup()
	if err != nil {
		return winProxyBackup{}, err
	}

	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	if err != nil {
		return winProxyBackup{}, err
	}
	defer key.Close()

	proxyServer := fmt.Sprintf("socks=%s:%s", host, port)
	if err := key.SetDWordValue("ProxyEnable", 1); err != nil {
		return winProxyBackup{}, err
	}
	if err := key.SetStringValue("ProxyServer", proxyServer); err != nil {
		return winProxyBackup{}, err
	}
	if err := key.SetStringValue("ProxyOverride", "<local>;127.0.0.1;localhost"); err != nil {
		return winProxyBackup{}, err
	}

	backup.active = true
	if err := persistProxyBackup(backup); err != nil {
		_ = restoreWinProxy(backup)
		return winProxyBackup{}, err
	}
	refreshWinProxySettings()
	return backup, nil
}

func persistProxyBackup(backup winProxyBackup) error {
	_ = os.MkdirAll(clientSettingsDir(), 0o755)
	b, err := json.Marshal(backup)
	if err != nil {
		return err
	}
	return os.WriteFile(proxyBackupPath(), b, 0o644)
}

func clearPersistedProxyBackup() {
	_ = os.Remove(proxyBackupPath())
}

func restoreOrphanedWinProxy() {
	b, err := os.ReadFile(proxyBackupPath())
	if err != nil {
		return
	}
	var backup winProxyBackup
	if json.Unmarshal(b, &backup) != nil {
		return
	}
	if err := restoreWinProxy(backup); err != nil {
		fmt.Println("ReProxy Client: failed to restore Windows proxy:", err)
		return
	}
	clearPersistedProxyBackup()
	fmt.Println("ReProxy Client: restored Windows proxy settings from previous session")
}

func restoreWinProxy(backup winProxyBackup) error {
	if !backup.active {
		return nil
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()

	if err := key.SetDWordValue("ProxyEnable", backup.enabled); err != nil {
		return err
	}
	if backup.server != "" {
		if err := key.SetStringValue("ProxyServer", backup.server); err != nil {
			return err
		}
	} else {
		_ = key.DeleteValue("ProxyServer")
	}
	if backup.override != "" {
		if err := key.SetStringValue("ProxyOverride", backup.override); err != nil {
			return err
		}
	} else {
		_ = key.DeleteValue("ProxyOverride")
	}

	refreshWinProxySettings()
	clearPersistedProxyBackup()
	return nil
}

func refreshWinProxySettings() {
	wininet := syscall.NewLazyDLL("wininet.dll")
	setOption := wininet.NewProc("InternetSetOptionW")
	const (
		internetOptionSettingsChanged = 39
		internetOptionRefresh         = 37
	)
	_, _, _ = setOption.Call(0, internetOptionSettingsChanged, 0, 0)
	_, _, _ = setOption.Call(0, internetOptionRefresh, 0, 0)

	user32 := syscall.NewLazyDLL("user32.dll")
	sendTimeout := user32.NewProc("SendMessageTimeoutW")
	const wmSettingChange = 0x001A
	name, _ := syscall.UTF16PtrFromString("Internet Settings")
	_, _, _ = sendTimeout.Call(
		0xFFFF, // HWND_BROADCAST
		wmSettingChange,
		0,
		uintptr(unsafe.Pointer(name)),
		0x0002, // SMTO_ABORTIFHUNG
		1000,
		0,
	)
}
