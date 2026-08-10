package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os/exec"
	"runtime"
	"sync"
	"time"
)

//go:embed ui/*
var uiFiles embed.FS

type webApp struct {
	mu               sync.Mutex
	logMu            sync.Mutex
	mgr              *tunnelManager
	srv              *socksServer
	running          bool
	systemProxyWant  bool
	listen           string
	logs             []string
	maxLogs          int
	winProxy         winProxyBackup
}

func newWebApp() *webApp {
	return &webApp{maxLogs: 200}
}

func (a *webApp) appendLog(line string) {
	a.logMu.Lock()
	a.logs = append(a.logs, line)
	if len(a.logs) > a.maxLogs {
		a.logs = a.logs[len(a.logs)-a.maxLogs:]
	}
	a.logMu.Unlock()
}

func (a *webApp) snapshotLogs() []string {
	a.logMu.Lock()
	defer a.logMu.Unlock()
	out := make([]string, len(a.logs))
	copy(out, a.logs)
	return out
}

func (a *webApp) status() map[string]any {
	a.mu.Lock()
	running := a.running
	var proxyOnline bool
	var proxyIP string
	if a.mgr != nil {
		proxyOnline = a.mgr.isProxyOnline()
		proxyIP = a.mgr.getProxyIP()
	}
	a.mu.Unlock()
	a.logMu.Lock()
	logs := make([]string, len(a.logs))
	copy(logs, a.logs)
	a.logMu.Unlock()
	return map[string]any{
		"running":           running,
		"proxyOnline":       proxyOnline,
		"proxyIp":           proxyIP,
		"systemProxyActive": a.winProxy.active,
		"logs":              logs,
	}
}

func (a *webApp) syncSystemProxyLocked() {
	if !a.systemProxyWant || !a.running || a.mgr == nil || !a.mgr.isProxyOnline() {
		if a.winProxy.active {
			if err := restoreWinProxy(a.winProxy); err != nil {
				a.appendLog("关闭系统代理失败: " + err.Error())
			} else {
				a.appendLog("已关闭 Windows 系统代理")
			}
			a.winProxy = winProxyBackup{}
		}
		return
	}
	if a.winProxy.active {
		return
	}
	listen := a.listen
	if listen == "" {
		listen = "127.0.0.1:1080"
	}
	backup, err := applyWinProxy(listen)
	if err != nil {
		a.appendLog("设置系统代理失败: " + err.Error())
		return
	}
	a.winProxy = backup
	a.appendLog("已启用 Windows 系统代理 (PAC/SOCKS5) → " + listen)
}

func (a *webApp) onProxyStateChanged(online bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !online && a.winProxy.active {
		if err := restoreWinProxy(a.winProxy); err != nil {
			a.appendLog("关闭系统代理失败: " + err.Error())
		} else {
			a.appendLog("被控机离线，已关闭系统代理以恢复本机网络")
		}
		a.winProxy = winProxyBackup{}
		return
	}
	if online {
		a.syncSystemProxyLocked()
	}
}

func (a *webApp) stopLocked() {
	if a.winProxy.active {
		if err := restoreWinProxy(a.winProxy); err != nil {
			a.appendLog("恢复系统代理失败: " + err.Error())
		} else {
			a.appendLog("已恢复 Windows 系统代理设置")
		}
		a.winProxy = winProxyBackup{}
	}
	if a.mgr != nil {
		a.mgr.stop()
		a.mgr = nil
	}
	if a.srv != nil {
		_ = a.srv.Close()
		a.srv = nil
	}
	a.running = false
}

func (a *webApp) start(s settings, systemProxy bool) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.stopLocked()
	if s.Listen == "" {
		s.Listen = "127.0.0.1:1080"
	}
	if s.Token == "" {
		s.Token = defaultClientSettings().Token
	}

	a.systemProxyWant = systemProxy
	a.listen = s.Listen
	a.mgr = newTunnelManager(s)
	a.mgr.logf = a.appendLog
	a.mgr.onProxyState = a.onProxyStateChanged
	go a.mgr.run()
	a.srv = newSocksServer(s.Listen, a.mgr)
	a.running = true

	go func() {
		err := a.srv.Serve()
		if err != nil {
			a.appendLog("SOCKS stopped: " + err.Error())
		}
		a.mu.Lock()
		a.running = false
		a.srv = nil
		a.mu.Unlock()
	}()

	a.appendLog("Started · SOCKS5 " + s.Listen + " · device " + s.DeviceID)
	if systemProxy {
		a.appendLog("已勾选系统代理：被控机在线后将自动启用（未在线时不影响本机网络）")
	} else {
		a.appendLog("未启用系统代理，本机网络不受影响；可用 Firefox 手动设 SOCKS5")
	}
	return nil
}

func (a *webApp) stop() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.stopLocked()
	a.appendLog("Stopped")
}

func runWebUI() {
	restoreOrphanedWinProxy()
	app := newWebApp()
	saved := loadClientSettings()

	mux := http.NewServeMux()
	sub, _ := fs.Sub(uiFiles, "ui")
	mux.Handle("/", http.FileServer(http.FS(sub)))

	mux.HandleFunc("/api/settings", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.Method {
		case http.MethodGet:
			_ = json.NewEncoder(w).Encode(saved)
		case http.MethodPost:
			var body clientSettings
			if json.NewDecoder(r.Body).Decode(&body) != nil {
				http.Error(w, "bad json", http.StatusBadRequest)
				return
			}
			saveClientSettings(body)
			saved = body
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(app.status())
	})

	mux.HandleFunc("/api/start", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body clientSettings
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		if body.Server == "" || body.DeviceID == "" {
			http.Error(w, "server and deviceId required", http.StatusBadRequest)
			return
		}
		if body.Listen == "" {
			body.Listen = "127.0.0.1:1080"
		}
		saveClientSettings(body)
		saved = body
		err := app.start(settings{
			Server:   body.Server,
			DeviceID: body.DeviceID,
			Token:    body.Token,
			Listen:   body.Listen,
		}, body.SystemProxy)
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("/api/test-ip", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")

		type testResult struct {
			out map[string]any
		}
		done := make(chan testResult, 1)
		go func() {
			app.mu.Lock()
			running := app.running
			listen := "127.0.0.1:1080"
			proxyOnline := false
			if app.mgr != nil {
				proxyOnline = app.mgr.isProxyOnline()
			}
			if app.srv != nil {
				listen = app.srv.listen
			}
			app.mu.Unlock()

			out := map[string]any{
				"running":     running,
				"proxyOnline": proxyOnline,
			}
			if !running {
				out["error"] = "请先点击「启动代理」"
				done <- testResult{out: out}
				return
			}
			if !proxyOnline {
				out["error"] = "被控机 Proxy 离线，请检查 device.id 与被控机 ReProxy 是否运行"
				directIP, directErr := fetchDirectIP()
				if directIP != "" {
					out["directIp"] = directIP
				}
				if directErr != nil {
					out["directError"] = directErr.Error()
				}
				done <- testResult{out: out}
				return
			}

			directIP, directErr := fetchDirectIP()
			if directIP != "" {
				out["directIp"] = directIP
			}
			if directErr != nil {
				out["directError"] = directErr.Error()
			}

			proxyIP, err := fetchIPViaSOCKS(listen)
			if err != nil {
				out["error"] = err.Error()
				done <- testResult{out: out}
				return
			}
			out["proxyIp"] = proxyIP
			out["changed"] = directIP != "" && proxyIP != "" && directIP != proxyIP
			out["message"] = fmt.Sprintf("本机 %s → 代理 %s", directIP, proxyIP)
			app.appendLog("检测出口 IP: " + fmt.Sprint(out["message"]))
			done <- testResult{out: out}
		}()

		select {
		case res := <-done:
			_ = json.NewEncoder(w).Encode(res.out)
		case <-time.After(50 * time.Second):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"error": "检测超时（50秒），被控机可能无法访问外网",
			})
		}
	})

	mux.HandleFunc("/api/stop", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		app.stop()
		w.WriteHeader(http.StatusNoContent)
	})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fatal(err)
	}
	addr := ln.Addr().String()
	url := "http://" + addr + "/"
	openBrowser(url)

	srv := &http.Server{Handler: mux}
	fmt.Println("ReProxy Client UI:", url)
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fatal(err)
	}
}

func openBrowser(url string) {
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		_ = exec.Command("open", url).Start()
	default:
		_ = exec.Command("xdg-open", url).Start()
	}
}
