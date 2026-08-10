//go:build !windows

package main

import "fmt"

func launchBrowserWithSOCKS(listen, openURL string) (string, error) {
	return "", fmt.Errorf("launch browser with proxy is only supported on Windows")
}
