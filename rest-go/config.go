package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "embed"
)

//go:embed agent.config.json
var embeddedConfig []byte

type settings struct {
	Server   string
	DeviceID string
	Token    string
}

func agentLog(message string) {
	line := time.Now().Format("2006-01-02 15:04:05") + " " + message
	if version == "dev" {
		fmt.Println(line)
	}
	_ = osMkdirAll(settingsDir())
	f, err := os.OpenFile(string(logPath()), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		_, _ = f.WriteString(line + "\n")
		_ = f.Close()
	}
}

func readJSONFile(path pathRef) map[string]any {
	if !path.IsFile() {
		return map[string]any{}
	}
	b, err := os.ReadFile(string(path))
	if err != nil {
		return map[string]any{}
	}
	var out map[string]any
	if json.Unmarshal(b, &out) != nil {
		return map[string]any{}
	}
	return out
}

func loadConfig() map[string]any {
	candidates := []pathRef{
		configPathLocal(),
		pathRef(filepath.Join(filepath.Dir(os.Args[0]), "agent.config.json")),
	}
	if version == "dev" {
		candidates = append(candidates, pathRef(filepath.Join("..", "agent", "agent.config.json")))
	}
	for _, p := range candidates {
		if p.IsFile() {
			return readJSONFile(p)
		}
	}
	if len(embeddedConfig) > 0 {
		var out map[string]any
		if json.Unmarshal(embeddedConfig, &out) == nil {
			return out
		}
	}
	return map[string]any{}
}

func cfgString(cfg map[string]any, key string) string {
	v, ok := cfg[key]
	if !ok || v == nil {
		return ""
	}
	return stringsTrim(fmt.Sprint(v))
}

func ensureDeviceID(explicit string) string {
	if explicit = stringsTrim(explicit); explicit != "" {
		id := sanitizeDeviceID(explicit)
		_ = osMkdirAll(settingsDir())
		_ = writeTextFile(deviceIDPath(), id)
		return id
	}
	if saved := stringsTrim(readTextFile(deviceIDPath())); saved != "" {
		return sanitizeDeviceID(saved)
	}
	host, _ := os.Hostname()
	host = sanitizeDeviceID(host)
	if len(host) > 16 {
		host = host[:16]
	}
	suffix := fmt.Sprintf("%08X", time.Now().UnixNano()&0xffffffff)
	var id string
	if host != "" && host != "PC-UNKNOWN" {
		id = sanitizeDeviceID(host + "-" + suffix)
	} else {
		id = sanitizeDeviceID("PC-" + suffix)
	}
	_ = osMkdirAll(settingsDir())
	_ = writeTextFile(deviceIDPath(), id)
	agentLog("Generated device ID: " + id)
	return id
}

func resolveSettings() settings {
	cfg := loadConfig()
	configFlag := flag.String("config", "", "JSON config file path")
	serverFlag := flag.String("server", os.Getenv("SERVER"), "WebSocket server URL")
	deviceFlag := flag.String("device-id", os.Getenv("DEVICE_ID"), "Device ID")
	tokenFlag := flag.String("token", os.Getenv("ACCESS_TOKEN"), "Access token")
	flag.Parse()

	if *configFlag != "" {
		for k, v := range readJSONFile(pathRef(*configFlag)) {
			cfg[k] = v
		}
	}

	server := stringsTrim(*serverFlag)
	if server == "" {
		server = cfgString(cfg, "server")
	}
	if server == "" {
		server = "ws://localhost:8080"
	}

	token := stringsTrim(*tokenFlag)
	if token == "" {
		token = cfgString(cfg, "token")
	}
	if token == "" {
		token = "remote-screen-dev"
	}

	explicit := stringsTrim(*deviceFlag)
	if explicit == "" {
		explicit = cfgString(cfg, "deviceId")
	}
	deviceID := ensureDeviceID(explicit)

	return settings{
		Server:   server,
		DeviceID: deviceID,
		Token:    token,
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
	return fmt.Sprintf("%s/ws?role=term&deviceId=%s&token=%s", base, deviceID, token)
}

func serverHTTPBase(server string) string {
	base := stringsTrimRight(server, "/")
	switch {
	case strings.HasPrefix(base, "wss://"):
		return "https://" + base[len("wss://"):]
	case strings.HasPrefix(base, "ws://"):
		return "http://" + base[len("ws://"):]
	case strings.HasPrefix(base, "https://"), strings.HasPrefix(base, "http://"):
		return base
	default:
		return "http://" + base
	}
}

func stringsTrimRight(s, cut string) string {
	return stringsTrim(strings.TrimRight(s, cut))
}
