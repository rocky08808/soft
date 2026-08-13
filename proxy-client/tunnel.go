package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type tunnelManager struct {
	settings settings
	conn     *websocket.Conn
	writeMu  sync.Mutex
	ready    chan struct{}
	opens    sync.Map
	streams  sync.Map
	logf     func(string)
	stopCh   chan struct{}
	stopOnce sync.Once
	proxyOnline bool
	proxyMu     sync.RWMutex
	proxyIP     string
	proxyIPMu   sync.RWMutex
	connected   atomic.Uint32
	reconnecting atomic.Uint32
	onProxyState func(online bool)
}

func (m *tunnelManager) setProxyOnline(online bool) {
	m.proxyMu.Lock()
	m.proxyOnline = online
	m.proxyMu.Unlock()
}

func (m *tunnelManager) isProxyOnline() bool {
	m.proxyMu.RLock()
	defer m.proxyMu.RUnlock()
	return m.proxyOnline
}

func (m *tunnelManager) setProxyIP(ip string) {
	ip = stringsTrim(ip)
	m.proxyIPMu.Lock()
	m.proxyIP = ip
	m.proxyIPMu.Unlock()
}

func (m *tunnelManager) getProxyIP() string {
	m.proxyIPMu.RLock()
	defer m.proxyIPMu.RUnlock()
	return m.proxyIP
}

func (m *tunnelManager) setConnected(v bool) {
	if v {
		m.connected.Store(1)
		return
	}
	m.connected.Store(0)
}

func (m *tunnelManager) isConnected() bool {
	return m.connected.Load() == 1
}

func (m *tunnelManager) setReconnecting(v bool) {
	if v {
		m.reconnecting.Store(1)
		return
	}
	m.reconnecting.Store(0)
}

func (m *tunnelManager) isReconnecting() bool {
	return m.reconnecting.Load() == 1
}

func (m *tunnelManager) applyProxyIP(msg map[string]any) {
	if ip := stringsTrim(fmt.Sprint(msg["proxyIp"])); ip != "" && ip != "<nil>" {
		m.setProxyIP(ip)
	}
}

func (m *tunnelManager) log(line string) {
	if m.logf != nil {
		m.logf(line)
		return
	}
	fmt.Println(line)
}

func newTunnelManager(s settings) *tunnelManager {
	return &tunnelManager{
		settings: s,
		ready:    make(chan struct{}),
		stopCh:   make(chan struct{}),
	}
}

func (m *tunnelManager) stopped() bool {
	select {
	case <-m.stopCh:
		return true
	default:
		return false
	}
}

func (m *tunnelManager) stop() {
	m.stopOnce.Do(func() {
		m.setReconnecting(false)
		close(m.stopCh)
		m.resetConnection()
	})
}

func (m *tunnelManager) run() {
	url := buildWSURL(m.settings.Server, m.settings.DeviceID, m.settings.Token)
	for {
		if m.stopped() {
			return
		}
		if err := m.connect(url); err != nil {
			if m.stopped() {
				return
			}
			errText := strings.ToLower(err.Error())
			if strings.Contains(errText, "4000") && strings.Contains(errText, "replaced") {
				m.log("连接被另一个 ProxyClient 顶替。请结束多余的 ProxyClient.exe，只保留一个后再点「启动代理」。")
				return
			}
			m.log(fmt.Sprintf("proxy tunnel disconnected: %v (retry in 1s)", err))
			m.resetConnection()
			m.setReconnecting(true)
			select {
			case <-m.stopCh:
				m.setReconnecting(false)
				return
			case <-time.After(1 * time.Second):
			}
			m.log("正在重连服务器…")
			continue
		}
	}
}

func (m *tunnelManager) failPendingOpens(err error) {
	if err == nil {
		err = fmt.Errorf("proxy unavailable")
	}
	m.opens.Range(func(key, value any) bool {
		if ch, ok := value.(chan openResult); ok {
			select {
			case ch <- openResult{err: err}:
			default:
				ch <- openResult{err: err}
			}
		}
		m.opens.Delete(key)
		return true
	})
	m.streams.Range(func(key, value any) bool {
		if ch, ok := value.(chan []byte); ok {
			close(ch)
		}
		m.streams.Delete(key)
		return true
	})
}

func (m *tunnelManager) resetConnection() {
	m.setConnected(false)
	m.setProxyOnline(false)
	m.setProxyIP("")
	m.writeMu.Lock()
	if m.conn != nil {
		_ = m.conn.Close()
		m.conn = nil
	}
	m.writeMu.Unlock()
	m.ready = make(chan struct{})
	m.failPendingOpens(fmt.Errorf("connection lost"))
}

func (m *tunnelManager) connect(url string) error {
	dialer := websocket.Dialer{
		HandshakeTimeout: 30 * time.Second,
	}
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return err
	}

	m.writeMu.Lock()
	m.conn = conn
	m.writeMu.Unlock()
	m.setConnected(true)
	m.setReconnecting(false)
	close(m.ready)

	logURL := url
	if i := strings.Index(logURL, "token="); i >= 0 {
		logURL = logURL[:i] + "token=***"
	}
	m.log("proxy tunnel connected: " + logURL)

	defer m.resetConnection()

	conn.SetReadLimit(4 * 1024 * 1024)
	_ = conn.SetReadDeadline(time.Now().Add(180 * time.Second))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(180 * time.Second))
	})

	stopPing := make(chan struct{})
	go m.pingLoop(conn, stopPing)
	defer close(stopPing)

	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		_ = conn.SetReadDeadline(time.Now().Add(180 * time.Second))

		var msg map[string]any
		if json.Unmarshal(raw, &msg) != nil {
			continue
		}
		m.dispatch(msg)
	}
}

func (m *tunnelManager) pingLoop(conn *websocket.Conn, stop <-chan struct{}) {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			m.writeMu.Lock()
			err := conn.WriteMessage(websocket.PingMessage, nil)
			m.writeMu.Unlock()
			if err != nil {
				return
			}
		}
	}
}

type openResult struct {
	ok  bool
	err error
}

func (m *tunnelManager) notifyProxyState(online bool) {
	if m.onProxyState != nil {
		m.onProxyState(online)
	}
}

func (m *tunnelManager) deliverStreamData(id string, data []byte) {
	value, ok := m.streams.Load(id)
	if !ok {
		return
	}
	ch, ok := value.(chan []byte)
	if !ok {
		return
	}
	payload := append([]byte(nil), data...)
	select {
	case ch <- payload:
	case <-time.After(45 * time.Second):
		m.log(fmt.Sprintf("代理数据阻塞，关闭连接 %s", id))
		m.closeTunnel(id)
	}
}

func (m *tunnelManager) dispatch(msg map[string]any) {
	switch fmt.Sprint(msg["type"]) {
	case "registered":
		if online, ok := msg["proxyOnline"].(bool); ok {
			m.setProxyOnline(online)
			m.applyProxyIP(msg)
			if online {
				ip := m.getProxyIP()
				if ip != "" {
					m.log("被控机 Proxy 已在线，出口 IP: " + ip)
				} else {
					m.log("被控机 Proxy 已在线，请在浏览器设置 SOCKS5 代理后访问 ifconfig.me")
				}
			} else {
				m.log("警告：被控机 Proxy 未在线。请确认被控机已装 ReProxy 且 device.id 与这里填的完全一致")
			}
			m.notifyProxyState(online)
		}
		return
	case "proxy_online":
		wasOffline := !m.isProxyOnline()
		m.setProxyOnline(true)
		m.applyProxyIP(msg)
		ip := m.getProxyIP()
		if wasOffline {
			if ip != "" {
				m.log("被控机 Proxy 已重连，出口 IP: " + ip)
			} else {
				m.log("被控机 Proxy 已重连")
			}
		} else if ip != "" {
			m.log("被控机 Proxy 已上线，出口 IP: " + ip)
		} else {
			m.log("被控机 Proxy 已上线")
		}
		m.notifyProxyState(true)
		return
	case "proxy_offline":
		m.failPendingOpens(fmt.Errorf("被控机 Proxy 离线"))
		m.setProxyOnline(false)
		m.setProxyIP("")
		m.log("被控机 Proxy 已离线，10 秒内自动重连…")
		m.notifyProxyState(false)
		return
	}

	id := stringsTrim(fmt.Sprint(msg["id"]))
	if id == "" {
		return
	}
	switch fmt.Sprint(msg["type"]) {
	case "proxy_open_ok":
		if value, ok := m.opens.Load(id); ok {
			if ch, ok := value.(chan openResult); ok {
				ch <- openResult{ok: true}
			}
			m.opens.Delete(id)
		}
	case "proxy_open_err":
		errText := fmt.Sprint(msg["error"])
		m.log(fmt.Sprintf("代理连接失败: %s", errText))
		if value, ok := m.opens.Load(id); ok {
			if ch, ok := value.(chan openResult); ok {
				ch <- openResult{err: fmt.Errorf("%s", errText)}
			}
			m.opens.Delete(id)
		}
	case "proxy_data":
		raw, ok := msg["data"].(string)
		if !ok {
			return
		}
		data, err := base64.StdEncoding.DecodeString(raw)
		if err != nil || len(data) == 0 {
			return
		}
		m.deliverStreamData(id, data)
	case "proxy_close":
		if value, ok := m.streams.LoadAndDelete(id); ok {
			if ch, ok := value.(chan []byte); ok {
				close(ch)
			}
		}
	}
}

func (m *tunnelManager) waitReady() error {
	if m.isConnected() {
		return nil
	}
	select {
	case <-m.ready:
		if m.isConnected() {
			return nil
		}
		return fmt.Errorf("tunnel not connected")
	case <-time.After(60 * time.Second):
		return fmt.Errorf("tunnel not connected")
	case <-m.stopCh:
		return fmt.Errorf("stopped")
	}
}

func (m *tunnelManager) writeJSON(msg map[string]any) error {
	raw, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	m.writeMu.Lock()
	defer m.writeMu.Unlock()
	if m.conn == nil {
		return fmt.Errorf("not connected")
	}
	return m.conn.WriteMessage(websocket.TextMessage, raw)
}

func (m *tunnelManager) openTunnel(host string, port int) (string, chan []byte, error) {
	if err := m.waitReady(); err != nil {
		return "", nil, err
	}
	if !m.isProxyOnline() {
		return "", nil, fmt.Errorf("被控机 Proxy 离线，等待自动重连")
	}
	id, err := newTunnelID()
	if err != nil {
		return "", nil, err
	}
	resultCh := make(chan openResult, 1)
	streamCh := make(chan []byte, 256)
	m.opens.Store(id, resultCh)
	m.streams.Store(id, streamCh)

	if err := m.writeJSON(map[string]any{
		"type": "proxy_open",
		"id":   id,
		"host": host,
		"port": port,
	}); err != nil {
		m.opens.Delete(id)
		m.streams.Delete(id)
		close(streamCh)
		return "", nil, err
	}
	m.log(fmt.Sprintf("proxy_open sent %s -> %s:%d", id, host, port))

	select {
	case res := <-resultCh:
		if res.err != nil {
			m.streams.Delete(id)
			close(streamCh)
			return "", nil, res.err
		}
		if !res.ok {
			m.streams.Delete(id)
			close(streamCh)
			return "", nil, fmt.Errorf("proxy open failed")
		}
		return id, streamCh, nil
	case <-time.After(15 * time.Second):
		m.opens.Delete(id)
		m.streams.Delete(id)
		close(streamCh)
		_ = m.writeJSON(map[string]any{"type": "proxy_close", "id": id})
		return "", nil, fmt.Errorf("被控机无响应（请更新被控机 Proxy.exe 并确认服务器已部署最新 index.js）")
	}
}

func (m *tunnelManager) sendData(id string, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	return m.writeJSON(map[string]any{
		"type": "proxy_data",
		"id":   id,
		"data": base64.StdEncoding.EncodeToString(data),
	})
}

func (m *tunnelManager) closeTunnel(id string) {
	_ = m.writeJSON(map[string]any{"type": "proxy_close", "id": id})
	if value, ok := m.streams.LoadAndDelete(id); ok {
		if ch, ok := value.(chan []byte); ok {
			close(ch)
		}
	}
}

func newTunnelID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
