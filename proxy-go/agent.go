package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type wsOutbound struct {
	msgType int
	data    []byte
	release func()
}

type wsAgent struct {
	*agent
	conn     *websocket.Conn
	done     chan struct{}
	outbound chan wsOutbound
}

func newWSAgent(s settings) *wsAgent {
	core := newAgent(s)
	w := &wsAgent{
		agent:    core,
		done:     make(chan struct{}),
		outbound: make(chan wsOutbound, 512),
	}
	core.setSender(w.sendJSON, w.sendBinary)
	return w
}

func (w *wsAgent) run() {
	url := buildWSURL(w.settings.Server, w.settings.DeviceID, w.settings.Token)
	for {
		if err := w.connectOnce(url); err != nil {
			if strings.Contains(strings.ToLower(err.Error()), "replaced") {
				agentLog("Connection replaced, reconnecting in 1s...")
			} else {
				agentLog(fmt.Sprintf("Disconnected: %v. Retry in 1s...", err))
			}
			time.Sleep(1 * time.Second)
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

	stopWriter := make(chan struct{})
	go w.writeLoop(stopWriter)
	defer close(stopWriter)
	drainOutbound(w.outbound)

	stopPing := make(chan struct{})
	go w.pingLoop(conn, stopPing)
	defer close(stopPing)

	stopHeartbeat := make(chan struct{})
	go w.heartbeatLoop(stopHeartbeat)
	defer close(stopHeartbeat)

	for {
		mt, raw, err := conn.ReadMessage()
		if err != nil {
			if ce, ok := err.(*websocket.CloseError); ok && ce.Code == 4000 &&
				strings.Contains(strings.ToLower(ce.Text), "replaced") {
				return fmt.Errorf("replaced")
			}
			return err
		}
		_ = conn.SetReadDeadline(time.Now().Add(readTimeout))

		if mt == websocket.BinaryMessage {
			if id, data, ok := decodeProxyFrame(raw); ok {
				w.handleProxyBinary(id, data)
				continue
			}
			continue
		}

		var msg map[string]any
		if json.Unmarshal(raw, &msg) != nil {
			continue
		}
		w.handleMessage(msg)
	}
}

func drainOutbound(ch chan wsOutbound) {
	for {
		select {
		case item := <-ch:
			if item.release != nil {
				item.release()
			}
		default:
			return
		}
	}
}

func (w *wsAgent) writeLoop(stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case item := <-w.outbound:
			if w.conn == nil {
				if item.release != nil {
					item.release()
				}
				continue
			}
			err := w.conn.WriteMessage(item.msgType, item.data)
			if item.release != nil {
				item.release()
			}
			if err != nil {
				return
			}
		}
	}
}

func (w *wsAgent) queueOutbound(item wsOutbound) error {
	select {
	case w.outbound <- item:
		return nil
	case <-time.After(30 * time.Second):
		if item.release != nil {
			item.release()
		}
		return fmt.Errorf("write queue full")
	}
}

func (w *wsAgent) sendJSON(msg map[string]any) error {
	raw, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return w.queueOutbound(wsOutbound{msgType: websocket.TextMessage, data: raw})
}

func (w *wsAgent) sendBinary(frame []byte) error {
	release := func() { releaseProxyFrame(frame) }
	return w.queueOutbound(wsOutbound{
		msgType: websocket.BinaryMessage,
		data:    frame,
		release: release,
	})
}

func (w *wsAgent) pingLoop(conn *websocket.Conn, stop <-chan struct{}) {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			deadline := time.Now().Add(10 * time.Second)
			if err := conn.WriteControl(websocket.PingMessage, nil, deadline); err != nil {
				return
			}
		}
	}
}

func (w *wsAgent) heartbeatLoop(stop <-chan struct{}) {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if err := w.sendJSON(map[string]any{"type": "heartbeat"}); err != nil {
				agentLog("heartbeat send error: " + err.Error())
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
