package main

import (
	"bufio"
	"flag"
	"fmt"
	"net/url"
	"os"
	"runtime"
	"strings"
)

type settings struct {
	Server   string
	DeviceID string
	Token    string
	Listen   string
}

func resolveSettings() (settings, error) {
	server := flag.String("server", os.Getenv("SERVER"), "WebSocket server URL (ws:// or wss://)")
	device := flag.String("device-id", os.Getenv("DEVICE_ID"), "Remote device ID (required in CLI mode)")
	token := flag.String("token", os.Getenv("ACCESS_TOKEN"), "Access token")
	listen := flag.String("listen", "127.0.0.1:1080", "Local SOCKS5 listen address")
	flag.Parse()

	s := stringsTrim(*server)
	if s == "" {
		s = defaultClientSettings().Server
	}
	t := stringsTrim(*token)
	if t == "" {
		t = defaultClientSettings().Token
	}
	d := stringsTrim(*device)
	if len(os.Args) > 1 && d == "" {
		return settings{}, fmt.Errorf("missing --device-id (被控机 %%LOCALAPPDATA%%\\ReProxy\\device.id)")
	}
	return settings{
		Server:   s,
		DeviceID: d,
		Token:    t,
		Listen:   stringsTrim(*listen),
	}, nil
}

func buildWSURL(server, deviceID, token string) string {
	base := stringsTrimRight(server, "/")
	switch {
	case strings.HasPrefix(base, "http://"):
		base = "ws://" + base[len("http://"):]
	case strings.HasPrefix(base, "https://"):
		base = "wss://" + base[len("https://"):]
	case !strings.HasPrefix(base, "ws"):
		base = "ws://" + base
	}
	return fmt.Sprintf(
		"%s/ws?role=proxy_client&deviceId=%s&token=%s",
		base,
		url.QueryEscape(deviceID),
		url.QueryEscape(token),
	)
}

func stringsTrim(s string) string { return strings.TrimSpace(s) }

func stringsTrimRight(s, cut string) string {
	return stringsTrim(strings.TrimRight(s, cut))
}

func printUsage() {
	fmt.Println("ProxyClient - local SOCKS5 -> remote ReProxy agent")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  ProxyClient.exe --server wss://your-domain --device-id PC-xxx --token YOUR_TOKEN")
	fmt.Println()
	fmt.Println("Options:")
	flag.PrintDefaults()
	fmt.Println()
	fmt.Println("Example:")
	fmt.Println("  ProxyClient.exe --server wss://olxp.cc --device-id PC-ABC123 --token YOUR_TOKEN --listen 127.0.0.1:1080")
	fmt.Println()
	fmt.Println("Then set browser SOCKS5 to 127.0.0.1:1080 and open https://ifconfig.me")
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "Error:", err)
	waitBeforeExit(1)
}

func waitBeforeExit(code int) {
	if runtime.GOOS == "windows" && isInteractive() {
		fmt.Println()
		fmt.Println("Press Enter to exit...")
		_, _ = bufio.NewReader(os.Stdin).ReadBytes('\n')
	}
	os.Exit(code)
}

func isInteractive() bool {
	stat, err := os.Stdin.Stat()
	if err != nil {
		return true
	}
	return (stat.Mode() & os.ModeCharDevice) != 0
}
