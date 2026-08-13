package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"time"
)

func serveSOCKS(listen string, mgr *tunnelManager) error {
	srv := newSocksServer(listen, mgr)
	return srv.Serve()
}

func handleSOCKSConn(conn net.Conn, mgr *tunnelManager) {
	defer conn.Close()

	ver := make([]byte, 1)
	if _, err := io.ReadFull(conn, ver); err != nil {
		return
	}

	switch ver[0] {
	case 0x04:
		handleSOCKS4AfterVer(conn, mgr)
	case 0x05:
		handleSOCKS5AfterVer(conn, mgr)
	default:
		mgr.log(fmt.Sprintf("unsupported SOCKS version %d", ver[0]))
	}
}

func handleSOCKS4AfterVer(conn net.Conn, mgr *tunnelManager) {
	hdr := make([]byte, 7)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return
	}
	if hdr[0] != 0x01 {
		writeSOCKS4Reply(conn, 0x5b)
		return
	}

	port := int(binary.BigEndian.Uint16(hdr[1:3]))
	ip := net.IP(hdr[3:7])
	if _, err := readNullTerminated(conn); err != nil {
		return
	}

	host := ip.String()
	if ip[0] == 0 && ip[1] == 0 && ip[2] == 0 && ip[3] != 0 {
		domain, err := readNullTerminated(conn)
		if err != nil {
			return
		}
		host = domain
	}

	_ = conn.SetDeadline(time.Time{})

	id, err := mgr.openTunnel(host, port)
	if err != nil {
		mgr.log(fmt.Sprintf("proxy open %s:%d failed: %v", host, port, err))
		writeSOCKS4Reply(conn, 0x5b)
		return
	}

	if err := writeSOCKS4Reply(conn, 0x5a); err != nil {
		mgr.closeTunnel(id)
		return
	}
	relayTunnel(conn, mgr, id)
}

func handleSOCKS5AfterVer(conn net.Conn, mgr *tunnelManager) {
	if err := conn.SetDeadline(timeNow().Add(60 * time.Second)); err != nil {
		return
	}

	buf := make([]byte, 258)
	if _, err := io.ReadFull(conn, buf[:1]); err != nil {
		return
	}
	nMethods := int(buf[0])
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

	id, err := mgr.openTunnel(host, port)
	if err != nil {
		mgr.log(fmt.Sprintf("proxy open %s:%d failed: %v", host, port, err))
		_, _ = conn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	if _, err := conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		mgr.closeTunnel(id)
		return
	}
	relayTunnel(conn, mgr, id)
}

func relayTunnel(conn net.Conn, mgr *tunnelManager, id string) {
	defer mgr.closeTunnel(id)
	mgr.bindStream(id, conn)

	buf := make([]byte, 256*1024)
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
}

func writeSOCKS4Reply(conn net.Conn, code byte) error {
	_, err := conn.Write([]byte{0x00, code, 0, 0, 0, 0, 0, 0})
	return err
}

func readNullTerminated(conn net.Conn) (string, error) {
	var b []byte
	buf := make([]byte, 1)
	for {
		if _, err := io.ReadFull(conn, buf); err != nil {
			return "", err
		}
		if buf[0] == 0 {
			return string(b), nil
		}
		b = append(b, buf[0])
		if len(b) > 255 {
			return "", fmt.Errorf("string too long")
		}
	}
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
