package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

type httpProxyServer struct {
	listen string
	mgr    *tunnelManager
	ln     net.Listener
	mu     sync.Mutex
	logf   func(string)
}

func newHTTPProxyServer(listen string, mgr *tunnelManager) *httpProxyServer {
	return &httpProxyServer{listen: listen, mgr: mgr, logf: mgr.logf}
}

func (s *httpProxyServer) Serve() error {
	ln, err := net.Listen("tcp", s.listen)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.ln = ln
	s.mu.Unlock()

	s.log("HTTP proxy listening on " + s.listen + " (Chrome/Edge system proxy)")
	for {
		conn, err := ln.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.ln == nil
			s.mu.Unlock()
			if closed {
				return nil
			}
			return err
		}
		go handleHTTPProxyConn(conn, s.mgr)
	}
}

func (s *httpProxyServer) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ln == nil {
		return nil
	}
	err := s.ln.Close()
	s.ln = nil
	return err
}

func (s *httpProxyServer) log(line string) {
	if s.logf != nil {
		s.logf(line)
		return
	}
	fmt.Println(line)
}

func handleHTTPProxyConn(conn net.Conn, mgr *tunnelManager) {
	defer conn.Close()

	req, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		return
	}
	defer func() { _ = req.Body.Close() }()

	if req.Method == http.MethodConnect {
		handleHTTPConnectRequest(conn, req, mgr)
		return
	}
	handleHTTPForwardRequest(conn, req, mgr)
}

func handleHTTPConnectRequest(conn net.Conn, req *http.Request, mgr *tunnelManager) {
	host, portStr, err := net.SplitHostPort(req.Host)
	if err != nil {
		host = req.Host
		portStr = "443"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || host == "" {
		_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
		return
	}

	id, err := mgr.openTunnel(host, port)
	if err != nil {
		mgr.log(fmt.Sprintf("http proxy CONNECT %s:%d failed: %v", host, port, err))
		_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		return
	}
	if _, err := conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		mgr.closeTunnel(id)
		return
	}
	relayTunnel(conn, mgr, id)
}

func handleHTTPForwardRequest(conn net.Conn, req *http.Request, mgr *tunnelManager) {
	host := req.URL.Hostname()
	port := 80
	if req.URL.Port() != "" {
		if p, err := strconv.Atoi(req.URL.Port()); err == nil {
			port = p
		}
	}
	if host == "" && req.Host != "" {
		if h, p, err := net.SplitHostPort(req.Host); err == nil {
			host = h
			if pp, err := strconv.Atoi(p); err == nil {
				port = pp
			}
		} else {
			host = req.Host
		}
	}
	if host == "" {
		_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
		return
	}

	id, err := mgr.openTunnel(host, port)
	if err != nil {
		_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		return
	}

	path := req.URL.RequestURI()
	if path == "" {
		path = "/"
	}
	var reqBuf strings.Builder
	reqBuf.WriteString(fmt.Sprintf("%s %s HTTP/1.1\r\n", req.Method, path))
	reqBuf.WriteString(fmt.Sprintf("Host: %s\r\n", req.Host))
	for k, vals := range req.Header {
		for _, v := range vals {
			if strings.EqualFold(k, "Proxy-Connection") {
				continue
			}
			reqBuf.WriteString(fmt.Sprintf("%s: %s\r\n", k, v))
		}
	}
	reqBuf.WriteString("\r\n")
	if err := mgr.sendData(id, []byte(reqBuf.String())); err != nil {
		mgr.closeTunnel(id)
		return
	}
	if req.Body != nil {
		body, _ := io.ReadAll(req.Body)
		if len(body) > 0 {
			if err := mgr.sendData(id, body); err != nil {
				mgr.closeTunnel(id)
				return
			}
		}
	}
	relayTunnel(conn, mgr, id)
}
