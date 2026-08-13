package main

import (
	"encoding/hex"
	"errors"
	"sync"
)

const (
	proxyFrameData byte = 0x10
	proxyTunnelLen      = 16
	proxyFrameHeader    = 1 + proxyTunnelLen
)

var (
	errInvalidProxyFrame = errors.New("invalid proxy data frame")
	framePool            sync.Pool
)

func init() {
	framePool.New = func() any {
		b := make([]byte, 0, 256*1024+proxyFrameHeader)
		return &b
	}
}

func tunnelIDFromString(s string) ([16]byte, error) {
	var out [16]byte
	id, err := hex.DecodeString(s)
	if err != nil || len(id) != proxyTunnelLen {
		return out, errInvalidProxyFrame
	}
	copy(out[:], id)
	return out, nil
}

func tunnelIDToString(id [16]byte) string {
	return hex.EncodeToString(id[:])
}

func encodeProxyFrame(id [16]byte, payload []byte) []byte {
	need := proxyFrameHeader + len(payload)
	p := framePool.Get().(*[]byte)
	buf := (*p)[:0]
	if cap(buf) < need {
		buf = make([]byte, need)
	} else {
		buf = buf[:need]
	}
	buf[0] = proxyFrameData
	copy(buf[1:proxyFrameHeader], id[:])
	copy(buf[proxyFrameHeader:], payload)
	*p = buf
	return buf
}

func releaseProxyFrame(frame []byte) {
	if frame == nil {
		return
	}
	if cap(frame) < proxyFrameHeader || cap(frame) > 512*1024+proxyFrameHeader {
		return
	}
	p := frame[:0]
	framePool.Put(&p)
}

func decodeProxyFrame(frame []byte) (id [16]byte, payload []byte, ok bool) {
	if len(frame) < proxyFrameHeader || frame[0] != proxyFrameData {
		return id, nil, false
	}
	copy(id[:], frame[1:proxyFrameHeader])
	return id, frame[proxyFrameHeader:], true
}
