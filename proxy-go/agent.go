package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type wsAgent struct {
	*agent
	conn *websocket.Conn
	done chan struct{}
}

func newWSAgent(s settings) *wsAgent {
	core := newAgent(s)
	w := &wsAgent{agent: core, done: make(chan struct{})}
	core.setSender(w.sendJSON)
	return w
}

func (w *wsAgent) run() {
	url := buildWSURL(w.settings.Server, w.settings.DeviceID, w.settings.Token)
	for {
		if err := w.connectOnce(url); err != nil {
			if strings.Contains(strings.ToLower(err.Error()), "replaced") {
				agentLog("Connection replaced, reconnecting in 10s...")
			} else {
				agentLog(fmt.Sprintf("Disconnected: %v. Retry in 10s...", err))
			}
			time.Sleep(10 * time.Second)
			continue
		}
	}
}

func (w *wsAgent) connectOnce(url string) error {
	dialer := websocket.Dialer{
		HandshakeTimeout: 30 * time.Second,
	}
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return err
	}
	w.conn = conn
	defer conn.Close()
	defer w.closeAllTunnels()

	conn.SetReadLimit(4 * 1024 * 1024)
	readTimeout := 180 * time.Second
	_ = conn.SetReadDeadline(time.Now().Add(readTimeout))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(readTimeout))
	})

	logURL := url
	if i := strings.Index(logURL, "token="); i >= 0 {
		logURL = logURL[:i] + "token=***"
	}
	agentLog("Connecting to " + logURL)

	hostname, _ := os.Hostname()
	if err := w.sendJSON(map[string]any{
		"type":     "proxy_info",
		"hostname": hostname,
		"platform": "windows",
		"version":  localVersion(),
	}); err != nil {
		return err
	}
	agentLog(fmt.Sprintf("Proxy agent online: %s (%s) v%s", w.settings.DeviceID, hostname, localVersion()))
	go w.reportPublicIP()

	stopPing := make(chan struct{})
	go w.pingLoop(conn, stopPing)
	defer close(stopPing)

	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			if ce, ok := err.(*websocket.CloseError); ok && ce.Code == 4000 &&
				strings.Contains(strings.ToLower(ce.Text), "replaced") {
				return fmt.Errorf("replaced")
			}
			return err
		}
		_ = conn.SetReadDeadline(time.Now().Add(readTimeout))

		var msg map[string]any
		if json.Unmarshal(raw, &msg) != nil {
			continue
		}
		w.handleMessage(msg)
	}
}

func (w *wsAgent) sendJSON(msg map[string]any) error {
	raw, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.conn.WriteMessage(websocket.TextMessage, raw)
}

func (w *wsAgent) pingLoop(conn *websocket.Conn, stop <-chan struct{}) {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			w.writeMu.Lock()
			err := conn.WriteMessage(websocket.PingMessage, nil)
			w.writeMu.Unlock()
			if err != nil {
				return
			}
		}
	}
}

func (w *wsAgent) reportPublicIP() {
	ip := fetchPublicIP()
	if ip == "" {
		return
	}
	agentLog("Public IP: " + ip)
	_ = w.sendJSON(map[string]any{
		"type":     "proxy_info",
		"publicIp": ip,
	})
}
