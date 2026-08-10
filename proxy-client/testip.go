package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"time"
)

func socks5Connect(conn net.Conn, host string, port int) error {
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return err
	}
	buf := make([]byte, 2)
	if _, err := io.ReadFull(conn, buf); err != nil {
		return err
	}
	if buf[0] != 0x05 || buf[1] != 0x00 {
		return fmt.Errorf("socks handshake failed")
	}

	host = stringsTrim(host)
	hostBytes := []byte(host)
	req := make([]byte, 0, 7+len(hostBytes))
	req = append(req, 0x05, 0x01, 0x00, 0x03, byte(len(hostBytes)))
	req = append(req, hostBytes...)
	var portBuf [2]byte
	binary.BigEndian.PutUint16(portBuf[:], uint16(port))
	req = append(req, portBuf[:]...)
	if _, err := conn.Write(req); err != nil {
		return err
	}

	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return err
	}
	if hdr[1] != 0x00 {
		return fmt.Errorf("socks connect failed: code %d", hdr[1])
	}
	switch hdr[3] {
	case 0x01:
		_, err := io.ReadFull(conn, make([]byte, 4+2))
		return err
	case 0x03:
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(conn, lenBuf); err != nil {
			return err
		}
		_, err := io.ReadFull(conn, make([]byte, int(lenBuf[0])+2))
		return err
	case 0x04:
		_, err := io.ReadFull(conn, make([]byte, 16+2))
		return err
	default:
		return fmt.Errorf("unsupported socks atyp")
	}
}

func fetchIPViaSOCKS(listen string) (string, error) {
	conn, err := net.DialTimeout("tcp", listen, 8*time.Second)
	if err != nil {
		return "", fmt.Errorf("connect local socks: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))

	if err := socks5Connect(conn, "ifconfig.me", 80); err != nil {
		return "", fmt.Errorf("socks tunnel: %w", err)
	}
	if _, err := io.WriteString(conn, "GET /ip HTTP/1.1\r\nHost: ifconfig.me\r\nConnection: close\r\n\r\n"); err != nil {
		return "", err
	}

	reader := bufio.NewReader(conn)
	inBody := false
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return "", err
		}
		if !inBody {
			if line == "\r\n" {
				inBody = true
			}
			continue
		}
		ip := stringsTrim(line)
		if ip != "" {
			return ip, nil
		}
	}
}

func fetchDirectIP() (string, error) {
	conn, err := net.DialTimeout("tcp", "ifconfig.me:80", 8*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := io.WriteString(conn, "GET /ip HTTP/1.1\r\nHost: ifconfig.me\r\nConnection: close\r\n\r\n"); err != nil {
		return "", err
	}
	reader := bufio.NewReader(conn)
	inBody := false
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return "", err
		}
		if !inBody {
			if line == "\r\n" {
				inBody = true
			}
			continue
		}
		ip := stringsTrim(line)
		if ip != "" {
			return ip, nil
		}
	}
}
