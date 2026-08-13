package main

import (
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"
)

const proxyReadBuffer = 128 * 1024

type tunnel struct {
	conn net.Conn
}

type agent struct {
	settings   settings
	writeMu    sync.Mutex
	sendJSON   func(map[string]any) error
	sendBinary func([]byte) error
	tunnels    sync.Map
}

func newAgent(s settings) *agent {
	return &agent{settings: s}
}

func (a *agent) setSender(sendJSON func(map[string]any) error, sendBinary func([]byte) error) {
	a.sendJSON = sendJSON
	a.sendBinary = sendBinary
}

func (a *agent) writeJSON(msg map[string]any) error {
	if a.sendJSON == nil {
		return fmt.Errorf("sender not ready")
	}
	return a.sendJSON(msg)
}

func (a *agent) writeBinary(frame []byte) error {
	if a.sendBinary == nil {
		return fmt.Errorf("binary sender not ready")
	}
	return a.sendBinary(frame)
}

func (a *agent) handleMessage(msg map[string]any) {
	t := fmt.Sprint(msg["type"])
	switch t {
	case "proxy_open":
		a.handleProxyOpen(msg)
	case "proxy_close":
		a.handleProxyClose(msg)
	default:
		if t != "" {
			agentLog("ignore message type: " + t)
		}
	}
}

func (a *agent) handleProxyBinary(id string, data []byte) {
	if id == "" || len(data) == 0 {
		return
	}
	value, ok := a.tunnels.Load(id)
	if !ok {
		return
	}
	t := value.(*tunnel)
	_, _ = t.conn.Write(data)
}

func tunnelID(msg map[string]any) string {
	return stringsTrim(fmt.Sprint(msg["id"]))
}

func tunnelPort(msg map[string]any) int {
	switch v := msg["port"].(type) {
	case float64:
		return int(v)
	case int:
		return v
	case int64:
		return int(v)
	default:
		n, _ := strconv.Atoi(fmt.Sprint(v))
		return n
	}
}

func (a *agent) handleProxyOpen(msg map[string]any) {
	id := tunnelID(msg)
	host := stringsTrim(fmt.Sprint(msg["host"]))
	port := tunnelPort(msg)
	if id == "" || host == "" || port <= 0 {
		_ = a.writeJSON(map[string]any{
			"type":  "proxy_open_err",
			"id":    id,
			"error": "invalid proxy_open",
		})
		return
	}

	agentLog(fmt.Sprintf("proxy_open request %s -> %s:%d", id, host, port))

	go func() {
		addr := net.JoinHostPort(host, strconv.Itoa(port))
		conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
		if err != nil {
			agentLog(fmt.Sprintf("proxy_open %s %s failed: %v", id, addr, err))
			_ = a.writeJSON(map[string]any{
				"type":  "proxy_open_err",
				"id":    id,
				"error": err.Error(),
			})
			return
		}
		if tcp, ok := conn.(*net.TCPConn); ok {
			_ = tcp.SetNoDelay(true)
			_ = tcp.SetKeepAlive(true)
			_ = tcp.SetKeepAlivePeriod(30 * time.Second)
		}
		a.tunnels.Store(id, &tunnel{conn: conn})
		if err := a.writeJSON(map[string]any{"type": "proxy_open_ok", "id": id}); err != nil {
			_ = conn.Close()
			a.tunnels.Delete(id)
			return
		}
		agentLog(fmt.Sprintf("proxy_open ok %s -> %s", id, addr))
		a.pumpTunnel(id, conn)
	}()
}

func (a *agent) pumpTunnel(id string, conn net.Conn) {
	defer func() {
		_ = conn.Close()
		a.tunnels.Delete(id)
	}()
	buf := make([]byte, proxyReadBuffer)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			frame, ferr := encodeProxyData(id, buf[:n])
			if ferr != nil {
				return
			}
			if werr := a.writeBinary(frame); werr != nil {
				return
			}
		}
		if err != nil {
			_ = a.writeJSON(map[string]any{"type": "proxy_close", "id": id})
			return
		}
	}
}

func (a *agent) handleProxyClose(msg map[string]any) {
	id := tunnelID(msg)
	if id == "" {
		return
	}
	if value, ok := a.tunnels.LoadAndDelete(id); ok {
		_ = value.(*tunnel).conn.Close()
	}
}

func (a *agent) closeAllTunnels() {
	a.tunnels.Range(func(key, value any) bool {
		_ = value.(*tunnel).conn.Close()
		a.tunnels.Delete(key)
		return true
	})
}
