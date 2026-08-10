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
)

//go:embed ui/*
var uiFiles embed.FS

type webApp struct {
	mu      sync.Mutex
	mgr     *tunnelManager
	srv     *socksServer
	running bool
	logs    []string
	maxLogs int
}

func newWebApp() *webApp {
	return &webApp{maxLogs: 200}
}

func (a *webApp) appendLog(line string) {
	a.mu.Lock()
	a.logs = append(a.logs, line)
	if len(a.logs) > a.maxLogs {
		a.logs = a.logs[len(a.logs)-a.maxLogs:]
	}
	a.mu.Unlock()
}

func (a *webApp) snapshotLogs() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]string, len(a.logs))
	copy(out, a.logs)
	return out
}

func (a *webApp) status() map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	return map[string]any{
		"running": a.running,
		"logs":    a.logs,
	}
}

func (a *webApp) start(s settings) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.running {
		return fmt.Errorf("proxy already running")
	}
	if s.Listen == "" {
		s.Listen = "127.0.0.1:1080"
	}
		if s.Token == "" {
			s.Token = defaultClientSettings().Token
		}

	a.mgr = newTunnelManager(s)
	a.mgr.logf = a.appendLog
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
	return nil
}

func (a *webApp) stop() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.srv != nil {
		_ = a.srv.Close()
		a.srv = nil
	}
	a.running = false
	a.appendLog("Stopped")
}

func runWebUI() {
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
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
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
