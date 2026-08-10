package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

type ipTarget struct {
	addr string
	host string
	path string
}

var ipTargets = []ipTarget{
	{addr: "ip.sb:80", host: "ip.sb", path: "/"},
	{addr: "icanhazip.com:80", host: "icanhazip.com", path: "/"},
	{addr: "ifconfig.me:80", host: "ifconfig.me", path: "/ip"},
}

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

func readIPFromHTTP(conn net.Conn, host, path string, timeout time.Duration) (string, error) {
	_ = conn.SetDeadline(time.Now().Add(timeout))
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: ReProxyClient/1.0\r\nConnection: close\r\n\r\n", path, host)
	if _, err := io.WriteString(conn, req); err != nil {
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

func fetchIPOverTCP(addr, host, path string, timeout time.Duration) (string, error) {
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	return readIPFromHTTP(conn, host, path, timeout)
}

func fetchDirectIP() (string, error) {
	var lastErr error
	for _, target := range ipTargets {
		ip, err := fetchIPOverTCP(target.addr, target.host, target.path, 5*time.Second)
		if err == nil && ip != "" {
			return ip, nil
		}
		lastErr = err
	}
	if lastErr != nil {
		return "", fmt.Errorf("无法获取本机 IP: %v", lastErr)
	}
	return "", fmt.Errorf("无法获取本机 IP（请检查网络）")
}

func fetchIPViaSOCKS(listen string) (string, error) {
	var lastErr error
	for _, target := range ipTargets {
		ip, err := fetchIPViaSOCKSOnce(listen, target.host, target.path, 5*time.Second)
		if err == nil && ip != "" {
			return ip, nil
		}
		lastErr = err
	}
	if lastErr != nil {
		return "", fmt.Errorf("代理出口检测失败: %v", lastErr)
	}
	return "", fmt.Errorf("代理出口检测失败")
}

func fetchIPViaSOCKSOnce(listen, host, path string, timeout time.Duration) (string, error) {
	conn, err := net.DialTimeout("tcp", listen, 5*time.Second)
	if err != nil {
		return "", fmt.Errorf("连接本地 SOCKS 失败: %w", err)
	}
	defer conn.Close()

	tunnelDeadline := time.Now().Add(35 * time.Second)
	_ = conn.SetDeadline(tunnelDeadline)

	if err := socks5Connect(conn, host, 80); err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return "", fmt.Errorf("等待被控机连接 %s 超时（被控机 outbound 可能受限或被墙）", host)
		}
		if strings.Contains(err.Error(), "code 5") {
			return "", fmt.Errorf("被控机无法连接 %s（outbound 被拒绝）", host)
		}
		return "", fmt.Errorf("SOCKS 隧道失败: %w", err)
	}

	_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	return readIPFromHTTP(conn, host, path, 15*time.Second)
}
