package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"time"
)

const (
	updateInitialDelay  = 120 * time.Second
	updateCheckInterval = 6 * time.Hour
)

var updateExitRequested atomic.Bool

func httpUserAgent() string {
	return "ReST/" + localVersion()
}

func httpGetBytes(url string, timeout time.Duration) ([]byte, error) {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", httpUserAgent())
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("http %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

func fetchVersionsManifest(server string) (map[string]any, error) {
	url := serverHTTPBase(server) + "/download/versions.json"
	raw, err := httpGetBytes(url, 30*time.Second)
	if err != nil {
		return nil, err
	}
	var manifest map[string]any
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return nil, err
	}
	return manifest, nil
}

func manifestRestInfo(manifest map[string]any) map[string]any {
	info, _ := manifest["rest"].(map[string]any)
	if info == nil {
		return map[string]any{}
	}
	return info
}

func infoString(info map[string]any, key string) string {
	v, ok := info[key]
	if !ok || v == nil {
		return ""
	}
	return stringsTrim(fmt.Sprint(v))
}

func infoInt(info map[string]any, key string, fallback int) int {
	v, ok := info[key]
	if !ok || v == nil {
		return fallback
	}
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	default:
		i, err := strconv.Atoi(fmt.Sprint(v))
		if err != nil {
			return fallback
		}
		return i
	}
}

func downloadFile(url string, dest pathRef, minSize int) error {
	raw, err := httpGetBytes(url, 5*time.Minute)
	if err != nil {
		return err
	}
	if minSize > 0 && len(raw) < minSize {
		return fmt.Errorf("download too small: %d bytes", len(raw))
	}
	dir := filepath.Dir(string(dest))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if dest.IsFile() {
		_ = os.Remove(string(dest))
	}
	return os.WriteFile(string(dest), raw, 0o644)
}

func launchRestUpdater(zipPath, workDir, exe pathRef) error {
	ps1 := workDir.Join("update.ps1")
	pid := os.Getpid()
	script := fmt.Sprintf(`param()
$ErrorActionPreference = 'SilentlyContinue'
$pidToWait = %d
$zipPath = "%s"
$dir = "%s"
$exe = "%s"
Wait-Process -Id $pidToWait -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Get-Process -Name 'ReST' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Expand-Archive -LiteralPath $zipPath -DestinationPath $dir -Force
Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $exe) {
    Start-Process -FilePath $exe -WorkingDirectory $dir -WindowStyle Hidden
}
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "%s" -Force -ErrorAction SilentlyContinue
`, pid, zipPath, workDir, exe, ps1)

	if err := writeTextFile(ps1, script); err != nil {
		return err
	}

	cmd := exec.Command(
		"powershell.exe",
		"-NoProfile", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass",
		"-File", string(ps1),
	)
	cmd.Dir = string(workDir)
	hideExec(cmd)
	return cmd.Start()
}

func applyRestUpdate(server string, info map[string]any) error {
	base := serverHTTPBase(server)
	urlPath := infoString(info, "url")
	if urlPath == "" {
		urlPath = "/download/ReST.zip"
	}
	downloadURL := urlPath
	if !stringsHasPrefix(urlPath, "http") {
		downloadURL = base + urlPath
	}
	minSize := infoInt(info, "minSize", 524_288)
	workDir := settingsDir()
	_ = osMkdirAll(workDir)
	exe := workDir.Join("ReST.exe")
	zipPath := workDir.Join("ReST.update.zip")
	if err := downloadFile(downloadURL, zipPath, minSize); err != nil {
		return err
	}
	if remote := infoString(info, "version"); remote != "" {
		saveLocalVersion(remote)
	}
	if err := launchRestUpdater(zipPath, workDir, exe); err != nil {
		return err
	}
	updateExitRequested.Store(true)
	return nil
}

func updateAllowed() bool {
	if version == "dev" {
		return false
	}
	return os.Getenv("REST_SKIP_UPDATE") != "1"
}

func maybeAutoUpdate(server string) bool {
	if !updateAllowed() {
		return false
	}
	manifest, err := fetchVersionsManifest(server)
	if err != nil {
		agentLog("update manifest error: " + err.Error())
		return false
	}
	info := manifestRestInfo(manifest)
	remote := infoString(info, "version")
	if remote == "" || !versionIsNewer(remote, localVersion()) {
		return false
	}
	agentLog(fmt.Sprintf("update available: %s -> %s", localVersion(), remote))
	if err := applyRestUpdate(server, info); err != nil {
		agentLog("update failed: " + err.Error())
		return false
	}
	agentLog("update staged, restarting...")
	return true
}

func stringsHasPrefix(s, prefix string) bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}
