package main

import (
	"encoding/base64"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"
)

type tunnel struct {
	conn net.Conn
}

type agent struct {
	settings settings
	writeMu  sync.Mutex
	send     func(map[string]any) error
	tunnels  sync.Map
}

func newAgent(s settings) *agent {
	return &agent{settings: s}
}

func (a *agent) setSender(send func(map[string]any) error) {
	a.send = send
}

func (a *agent) writeJSON(msg map[string]any) error {
	if a.send == nil {
		return fmt.Errorf("sender not ready")
	}
	// sendJSON already serializes writes; locking here deadlocks.
	return a.send(msg)
}

func (a *agent) handleMessage(msg map[string]any) {
	t := fmt.Sprint(msg["type"])
	switch t {
	case "proxy_open":
		a.handleProxyOpen(msg)
	case "proxy_data":
		a.handleProxyData(msg)
	case "proxy_close":
		a.handleProxyClose(msg)
	default:
		if t != "" {
			agentLog("ignore message type: " + t)
		}
	}
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
	buf := make([]byte, 32*1024)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			payload := base64.StdEncoding.EncodeToString(buf[:n])
			if werr := a.writeJSON(map[string]any{
				"type": "proxy_data",
				"id":   id,
				"data": payload,
			}); werr != nil {
				return
			}
		}
		if err != nil {
			_ = a.writeJSON(map[string]any{"type": "proxy_close", "id": id})
			return
		}
	}
}

func (a *agent) handleProxyData(msg map[string]any) {
	id := tunnelID(msg)
	raw, ok := msg["data"].(string)
	if id == "" || !ok {
		return
	}
	value, ok := a.tunnels.Load(id)
	if !ok {
		return
	}
	t := value.(*tunnel)
	data, err := base64.StdEncoding.DecodeString(raw)
	if err != nil || len(data) == 0 {
		return
	}
	_, _ = t.conn.Write(data)
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
