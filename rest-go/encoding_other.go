//go:build !windows

package main

func decodeConsoleBytes(b []byte) string {
	return string(b)
}
