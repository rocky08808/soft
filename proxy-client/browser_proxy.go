//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func chromiumBrowserCandidates() []string {
	localApp := os.Getenv("LOCALAPPDATA")
	programFiles := os.Getenv("ProgramFiles")
	programFilesX86 := os.Getenv("ProgramFiles(x86)")
	return []string{
		filepath.Join(programFiles, "Google", "Chrome", "Application", "chrome.exe"),
		filepath.Join(programFilesX86, "Google", "Chrome", "Application", "chrome.exe"),
		filepath.Join(localApp, "Google", "Chrome", "Application", "chrome.exe"),
		filepath.Join(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"),
		filepath.Join(programFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
	}
}

func launchBrowserWithSOCKS(listen, openURL string) (string, error) {
	host, port, err := parseListenHostPort(listen)
	if err != nil {
		return "", err
	}
	if openURL == "" {
		openURL = "https://ip.sb/"
	}

	proxyArg := fmt.Sprintf("--proxy-server=socks5://%s:%s", host, port)
	resolverArg := "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"

	for _, exe := range chromiumBrowserCandidates() {
		if _, err := os.Stat(exe); err != nil {
			continue
		}
		cmd := exec.Command(exe, proxyArg, resolverArg, openURL)
		cmd.Dir = filepath.Dir(exe)
		if err := cmd.Start(); err != nil {
			continue
		}
		return exe, nil
	}
	return "", fmt.Errorf("未找到 Chrome 或 Edge，请手动设置 SOCKS5 %s:%s", host, port)
}
