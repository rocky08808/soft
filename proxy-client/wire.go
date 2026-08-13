package main

import (
	"encoding/hex"
	"errors"
)

const (
	proxyFrameData byte = 0x10
	proxyTunnelLen      = 16
)

var errInvalidProxyFrame = errors.New("invalid proxy data frame")

func encodeProxyData(tunnelID string, payload []byte) ([]byte, error) {
	id, err := hex.DecodeString(tunnelID)
	if err != nil || len(id) != proxyTunnelLen {
		return nil, errInvalidProxyFrame
	}
	out := make([]byte, 1+proxyTunnelLen+len(payload))
	out[0] = proxyFrameData
	copy(out[1:1+proxyTunnelLen], id)
	copy(out[1+proxyTunnelLen:], payload)
	return out, nil
}

func decodeProxyData(frame []byte) (tunnelID string, payload []byte, ok bool) {
	if len(frame) < 1+proxyTunnelLen || frame[0] != proxyFrameData {
		return "", nil, false
	}
	id := hex.EncodeToString(frame[1 : 1+proxyTunnelLen])
	return id, frame[1+proxyTunnelLen:], true
}
