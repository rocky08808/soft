package main

import (
	"fmt"
	"net"
	"sync"
)

type socksServer struct {
	listen string
	mgr    *tunnelManager
	ln     net.Listener
	mu     sync.Mutex
	logf   func(string)
}

func newSocksServer(listen string, mgr *tunnelManager) *socksServer {
	return &socksServer{listen: listen, mgr: mgr, logf: mgr.logf}
}

func (s *socksServer) Serve() error {
	ln, err := net.Listen("tcp", s.listen)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.ln = ln
	s.mu.Unlock()

	s.log("SOCKS5 listening on " + s.listen)
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
		go handleSOCKSConn(conn, s.mgr)
	}
}

func (s *socksServer) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ln == nil {
		return nil
	}
	err := s.ln.Close()
	s.ln = nil
	return err
}

func (s *socksServer) log(line string) {
	if s.logf != nil {
		s.logf(line)
		return
	}
	fmt.Println(line)
}
