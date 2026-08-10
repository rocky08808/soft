package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

type settings struct {
	Server   string
	DeviceID string
	Token    string
	Listen   string
}

func resolveSettings() settings {
	server := flag.String("server", os.Getenv("SERVER"), "WebSocket server URL")
	device := flag.String("device-id", os.Getenv("DEVICE_ID"), "Remote device ID to proxy through")
	token := flag.String("token", os.Getenv("ACCESS_TOKEN"), "Access token")
	listen := flag.String("listen", "127.0.0.1:1080", "Local SOCKS5 listen address")
	flag.Parse()

	s := stringsTrim(*server)
	if s == "" {
		s = "ws://localhost:8080"
	}
	t := stringsTrim(*token)
	if t == "" {
		t = "remote-screen-dev"
	}
	d := stringsTrim(*device)
	if d == "" {
		fmt.Fprintln(os.Stderr, "device-id is required")
		os.Exit(2)
	}
	return settings{
		Server:   s,
		DeviceID: d,
		Token:    t,
		Listen:   stringsTrim(*listen),
	}
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
	return fmt.Sprintf("%s/ws?role=proxy_client&deviceId=%s&token=%s", base, deviceID, token)
}

func stringsTrim(s string) string { return strings.TrimSpace(s) }

func stringsTrimRight(s, cut string) string {
	return stringsTrim(strings.TrimRight(s, cut))
}
