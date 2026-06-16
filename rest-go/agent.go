package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type agent struct {
	settings settings
	conn     *websocket.Conn
	done     chan struct{}
	writeMu  sync.Mutex
}

func newAgent(s settings) *agent {
	return &agent{settings: s, done: make(chan struct{})}
}

func (a *agent) run() {
	url := buildWSURL(a.settings.Server, a.settings.DeviceID, a.settings.Token)
	for {
		if updateExitRequested.Load() {
			agentLog("exiting for update")
			os.Exit(0)
		}
		if err := a.connectOnce(url); err != nil {
			if strings.Contains(strings.ToLower(err.Error()), "replaced") {
				return
			}
			agentLog(fmt.Sprintf("Disconnected: %v. Retry in 3s...", err))
			time.Sleep(3 * time.Second)
		}
	}
}

func (a *agent) connectOnce(url string) error {
	dialer := websocket.Dialer{
		HandshakeTimeout: 30 * time.Second,
		Proxy:            http.ProxyFromEnvironment,
	}
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return err
	}
	a.conn = conn
	defer conn.Close()

	conn.SetReadLimit(2 * 1024 * 1024)
	_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	})

	logURL := url
	if i := strings.Index(logURL, "token="); i >= 0 {
		logURL = logURL[:i] + "token=***"
	}
	agentLog("Connecting to " + logURL)

	hostname, _ := os.Hostname()
	if err := a.writeJSON(map[string]any{
		"type":     "term_info",
		"hostname": hostname,
		"platform": "windows",
		"version":  localVersion(),
	}); err != nil {
		return err
	}
	agentLog(fmt.Sprintf("Term agent online: %s (%s) v%s", a.settings.DeviceID, hostname, localVersion()))

	stopPing := make(chan struct{})
	go a.pingLoop(conn, stopPing)
	defer close(stopPing)

	updateStop := make(chan struct{})
	go a.autoUpdateLoop(updateStop)
	defer close(updateStop)

	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			if ce, ok := err.(*websocket.CloseError); ok && ce.Code == 4000 &&
				strings.Contains(strings.ToLower(ce.Text), "replaced") {
				agentLog("Connection replaced by newer ReST instance, exiting")
				return fmt.Errorf("replaced")
			}
			return err
		}
		_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		var msg map[string]any
		if json.Unmarshal(raw, &msg) != nil {
			continue
		}
		a.handleIncoming(msg)
		if updateExitRequested.Load() {
			agentLog("exiting for update")
			os.Exit(0)
		}
	}
}

func (a *agent) pingLoop(conn *websocket.Conn, stop <-chan struct{}) {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			a.writeMu.Lock()
			err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second))
			a.writeMu.Unlock()
			_ = err
		}
	}
}

func (a *agent) autoUpdateLoop(stop <-chan struct{}) {
	select {
	case <-time.After(updateInitialDelay):
	case <-stop:
		return
	}
	for {
		if updateExitRequested.Load() {
			return
		}
		if maybeAutoUpdate(a.settings.Server) {
			return
		}
		select {
		case <-time.After(updateCheckInterval):
		case <-stop:
			return
		}
	}
}

func (a *agent) handleIncoming(msg map[string]any) {
	msgType, _ := msg["type"].(string)
	switch msgType {
	case "registered":
		remote := stringsTrim(fmt.Sprint(msg["latestVersion"]))
		if remote != "" && versionIsNewer(remote, localVersion()) {
			go maybeAutoUpdate(a.settings.Server)
		}
	case "update_available":
		go maybeAutoUpdate(a.settings.Server)
	case "update":
		go a.handleUpdateRequest(fmt.Sprint(msg["id"]))
	case "terminal":
		go a.handleTerminal(msg)
	}
}

func (a *agent) writeJSON(v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	if a.conn == nil {
		return fmt.Errorf("connection closed")
	}
	return a.conn.WriteMessage(websocket.TextMessage, raw)
}

func (a *agent) handleTerminal(msg map[string]any) {
	reqID := fmt.Sprint(msg["id"])
	command := fmt.Sprint(msg["command"])
	shell := strings.ToLower(stringsTrim(fmt.Sprint(msg["shell"])))
	if shell != "powershell" {
		shell = "cmd"
	}
	cwd := stringsTrim(fmt.Sprint(msg["cwd"]))

	agentLog(fmt.Sprintf("exec [%s]: %s", shell, truncate(command, 120)))
	result := runCommand(command, shell, cwd)
	payload := map[string]any{
		"type":      "terminal_result",
		"id":        reqID,
		"command":   command,
		"shell":     shell,
		"stdout":    result.Stdout,
		"stderr":    result.Stderr,
		"exitCode":  result.ExitCode,
		"truncated": result.Truncated,
		"cwd":       result.CWD,
	}
	if err := a.writeJSON(payload); err != nil {
		agentLog("exec send failed: " + err.Error())
		return
	}
	agentLog(fmt.Sprintf(
		"exec done [%s] exit=%d stdout=%d stderr=%d",
		shell, result.ExitCode, len(result.Stdout), len(result.Stderr),
	))
}

func (a *agent) handleUpdateRequest(reqID string) {
	result := map[string]any{
		"type":         "update_result",
		"id":           reqID,
		"product":      "rest",
		"localVersion": localVersion(),
	}
	send := func() {
		_ = a.writeJSON(result)
	}

	if !updateAllowed() {
		if version == "dev" {
			result["ok"] = false
			result["status"] = "failed"
			result["error"] = "dev build cannot update"
		} else {
			result["ok"] = false
			result["status"] = "failed"
			result["error"] = "update disabled"
		}
		send()
		return
	}

	manifest, err := fetchVersionsManifest(a.settings.Server)
	if err != nil {
		result["ok"] = false
		result["status"] = "failed"
		result["error"] = err.Error()
		send()
		return
	}
	info := manifestRestInfo(manifest)
	remote := infoString(info, "version")
	result["remoteVersion"] = remote
	if remote == "" {
		result["ok"] = false
		result["status"] = "failed"
		result["error"] = "server version missing"
		send()
		return
	}
	if !versionIsNewer(remote, localVersion()) {
		result["ok"] = true
		result["status"] = "up_to_date"
		send()
		return
	}

	agentLog(fmt.Sprintf("manual update: %s -> %s", localVersion(), remote))
	result["ok"] = true
	result["status"] = "updating"
	send()

	if err := applyRestUpdate(a.settings.Server, info); err != nil {
		result["ok"] = false
		result["status"] = "failed"
		result["error"] = err.Error()
		send()
		return
	}
	agentLog("update staged, exiting...")
	os.Exit(0)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
