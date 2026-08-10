package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

func serveSOCKS(listen string, mgr *tunnelManager) error {
	srv := newSocksServer(listen, mgr)
	return srv.Serve()
}

func handleSOCKSConn(conn net.Conn, mgr *tunnelManager) {
	defer conn.Close()

	if err := conn.SetDeadline(timeNow().Add(60 * time.Second)); err != nil {
		return
	}

	buf := make([]byte, 258)
	if _, err := io.ReadFull(conn, buf[:2]); err != nil {
		return
	}
	if buf[0] != 0x05 {
		return
	}
	nMethods := int(buf[1])
	if _, err := io.ReadFull(conn, buf[:nMethods]); err != nil {
		return
	}
	if _, err := conn.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	if _, err := io.ReadFull(conn, buf[:4]); err != nil {
		return
	}
	if buf[1] != 0x01 {
		_, _ = conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	host, err := readSOCKSAddr(conn, buf[3], buf)
	if err != nil {
		return
	}
	var portBuf [2]byte
	if _, err := io.ReadFull(conn, portBuf[:]); err != nil {
		return
	}
	port := int(binary.BigEndian.Uint16(portBuf[:]))

	_ = conn.SetDeadline(time.Time{})

	id, stream, err := mgr.openTunnel(host, port)
	if err != nil {
		mgr.log(fmt.Sprintf("proxy open %s:%d failed: %v", host, port, err))
		_, _ = conn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer mgr.closeTunnel(id)

	if _, err := conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		buf := make([]byte, 32*1024)
		for {
			n, readErr := conn.Read(buf)
			if n > 0 {
				if err := mgr.sendData(id, buf[:n]); err != nil {
					return
				}
			}
			if readErr != nil {
				return
			}
		}
	}()

	go func() {
		defer wg.Done()
		for chunk := range stream {
			if len(chunk) == 0 {
				continue
			}
			if _, err := conn.Write(chunk); err != nil {
				return
			}
		}
	}()

	wg.Wait()
}

func readSOCKSAddr(conn net.Conn, atyp byte, buf []byte) (string, error) {
	switch atyp {
	case 0x01:
		if _, err := io.ReadFull(conn, buf[:4]); err != nil {
			return "", err
		}
		return fmt.Sprintf("%d.%d.%d.%d", buf[0], buf[1], buf[2], buf[3]), nil
	case 0x03:
		if _, err := io.ReadFull(conn, buf[:1]); err != nil {
			return "", err
		}
		n := int(buf[0])
		if _, err := io.ReadFull(conn, buf[:n]); err != nil {
			return "", err
		}
		return string(buf[:n]), nil
	case 0x04:
		if _, err := io.ReadFull(conn, buf[:16]); err != nil {
			return "", err
		}
		ip := net.IP(buf[:16])
		return ip.String(), nil
	default:
		return "", fmt.Errorf("unsupported atyp %d", atyp)
	}
}

func timeNow() time.Time { return time.Now() }
