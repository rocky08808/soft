//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows/registry"
)

type winProxyBackup struct {
	enabled       uint32
	server        string
	override      string
	autoConfigURL string
	active        bool
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

func pacFilePath() string {
	return filepath.Join(clientSettingsDir(), "proxy.pac")
}

func pacAutoConfigURL(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	p := filepath.ToSlash(abs)
	if len(p) >= 2 && p[1] == ':' {
		p = "/" + p
	}
	return "file://" + p
}

func writePACFile(host, port string) error {
	content := fmt.Sprintf(`function FindProxyForURL(url, host) {
  if (host === "localhost" ||
      host === "127.0.0.1" ||
      host === "[::1]" ||
      shExpMatch(host, "*.local") ||
      shExpMatch(host, "127.*") ||
      shExpMatch(host, "10.*") ||
      shExpMatch(host, "192.168.*") ||
      shExpMatch(host, "172.16.*") ||
      shExpMatch(host, "172.17.*") ||
      shExpMatch(host, "172.18.*") ||
      shExpMatch(host, "172.19.*") ||
      shExpMatch(host, "172.2*") ||
      shExpMatch(host, "172.30.*") ||
      shExpMatch(host, "172.31.*")) {
    return "DIRECT";
  }
  return "SOCKS5 %s:%s";
}
`, host, port)
	path := pacFilePath()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return err
	}
	return nil
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
	autoConfigURL, _, err := key.GetStringValue("AutoConfigURL")
	if err != nil {
		autoConfigURL = ""
	}
	return winProxyBackup{
		enabled:       uint32(enabled),
		server:        server,
		override:      override,
		autoConfigURL: autoConfigURL,
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

	if err := writePACFile(host, port); err != nil {
		return winProxyBackup{}, err
	}

	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	if err != nil {
		return winProxyBackup{}, err
	}
	defer key.Close()

	pacURL := pacAutoConfigURL(pacFilePath())
	if err := key.SetDWordValue("ProxyEnable", 1); err != nil {
		return winProxyBackup{}, err
	}
	if err := key.SetStringValue("AutoConfigURL", pacURL); err != nil {
		return winProxyBackup{}, err
	}
	_ = key.DeleteValue("ProxyServer")
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

func isReProxyWinProxyActive() bool {
	current, err := readWinProxyBackup()
	if err != nil {
		return false
	}
	pacPath := strings.ToLower(filepath.ToSlash(pacFilePath()))
	autoURL := strings.ToLower(current.autoConfigURL)
	if autoURL != "" {
		if strings.Contains(autoURL, "reproxyclient") && strings.Contains(autoURL, "proxy.pac") {
			return true
		}
		if strings.Contains(autoURL, strings.ToLower(pacPath)) {
			return true
		}
	}
	server := strings.ToLower(strings.TrimSpace(current.server))
	if server == "socks=127.0.0.1:1080" || strings.HasPrefix(server, "socks=127.0.0.1:") {
		return true
	}
	return false
}

func forceDisableReProxyWinProxy() error {
	current, err := readWinProxyBackup()
	if err != nil {
		return err
	}
	clearPAC := isReProxyWinProxyActive()
	clearServer := strings.Contains(strings.ToLower(current.server), "socks=127.0.0.1")
	if !clearPAC && !clearServer {
		return nil
	}

	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()

	if err := key.SetDWordValue("ProxyEnable", 0); err != nil {
		return err
	}
	if clearPAC {
		_ = key.DeleteValue("AutoConfigURL")
	}
	if clearServer {
		_ = key.DeleteValue("ProxyServer")
	}
	_ = os.Remove(pacFilePath())
	clearPersistedProxyBackup()
	refreshWinProxySettings()
	return nil
}

func emergencyRestoreNetwork() {
	if b, err := os.ReadFile(proxyBackupPath()); err == nil {
		var backup winProxyBackup
		if json.Unmarshal(b, &backup) == nil && backup.active {
			if err := restoreWinProxy(backup); err == nil {
				fmt.Println("ReProxy: 已恢复之前的 Windows 代理设置")
				return
			}
		}
	}
	if isReProxyWinProxyActive() {
		if err := forceDisableReProxyWinProxy(); err != nil {
			fmt.Println("ReProxy: 关闭系统代理失败:", err)
			return
		}
		fmt.Println("ReProxy: 已关闭系统代理，本机网络应已恢复")
		return
	}
	fmt.Println("ReProxy: 未检测到 ReProxy 残留的系统代理设置")
}

func restoreOrphanedWinProxy() {
	emergencyRestoreNetwork()
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
	if backup.autoConfigURL != "" {
		if err := key.SetStringValue("AutoConfigURL", backup.autoConfigURL); err != nil {
			return err
		}
	} else {
		_ = key.DeleteValue("AutoConfigURL")
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

	_ = os.Remove(pacFilePath())
	refreshWinProxySettings()
	clearPersistedProxyBackup()
	return nil
}

func restoreWinProxyOrForce(backup winProxyBackup) {
	if err := restoreWinProxy(backup); err != nil || isReProxyWinProxyActive() {
		_ = forceDisableReProxyWinProxy()
	}
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
		0xFFFF,
		wmSettingChange,
		0,
		uintptr(unsafe.Pointer(name)),
		0x0002,
		1000,
		0,
	)
}
