package main

import (
	_ "embed"
	"encoding/json"
	"os"
	"path/filepath"
)

//go:embed default.config.json
var defaultClientConfig []byte

type clientSettings struct {
	Server      string `json:"server"`
	DeviceID    string `json:"deviceId"`
	Token       string `json:"token"`
	Listen      string `json:"listen"`
	SystemProxy bool   `json:"systemProxy"`
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

func proxyBackupPath() string {
	return filepath.Join(clientSettingsDir(), "proxy-backup.json")
}

func defaultClientSettings() clientSettings {
	out := clientSettings{
		Server: "wss://olxp.cc",
		Token:  "remote-screen-dev",
		Listen: "127.0.0.1:1080",
	}
	if len(defaultClientConfig) == 0 {
		return out
	}
	var cfg map[string]any
	if json.Unmarshal(defaultClientConfig, &cfg) != nil {
		return out
	}
	if v := stringsTrim(cfgString(cfg, "server")); v != "" {
		out.Server = v
	}
	if v := stringsTrim(cfgString(cfg, "token")); v != "" {
		out.Token = v
	}
	return out
}

func cfgString(cfg map[string]any, key string) string {
	v, ok := cfg[key]
	if !ok || v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return t
	default:
		return ""
	}
}

func loadClientSettings() clientSettings {
	out := defaultClientSettings()
	b, err := os.ReadFile(clientSettingsPath())
	if err != nil {
		return out
	}
	var saved clientSettings
	if json.Unmarshal(b, &saved) != nil {
		return out
	}
	if stringsTrim(saved.Server) != "" {
		out.Server = stringsTrim(saved.Server)
	}
	if stringsTrim(saved.DeviceID) != "" {
		out.DeviceID = stringsTrim(saved.DeviceID)
	}
	if stringsTrim(saved.Token) != "" {
		out.Token = stringsTrim(saved.Token)
	}
	if stringsTrim(saved.Listen) != "" {
		out.Listen = stringsTrim(saved.Listen)
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
