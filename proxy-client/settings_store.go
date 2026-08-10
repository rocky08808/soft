package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type clientSettings struct {
	Server   string `json:"server"`
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
	Listen   string `json:"listen"`
}

func clientSettingsDir() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local")
	}
	return filepath.Join(base, "ReProxyClient")
}

func clientSettingsPath() string {
	return filepath.Join(clientSettingsDir(), "settings.json")
}

func loadClientSettings() clientSettings {
	out := clientSettings{
		Listen: "127.0.0.1:1080",
		Token:  "remote-screen-dev",
	}
	b, err := os.ReadFile(clientSettingsPath())
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	if out.Listen == "" {
		out.Listen = "127.0.0.1:1080"
	}
	return out
}

func saveClientSettings(s clientSettings) {
	_ = os.MkdirAll(clientSettingsDir(), 0o755)
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(clientSettingsPath(), b, 0o644)
}
