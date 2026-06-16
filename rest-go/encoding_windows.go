//go:build windows

package main

import (
	"syscall"
	"unicode/utf8"
	"unsafe"
)

const cpACP = 0

func decodeConsoleBytes(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	if utf8.Valid(b) {
		return string(b)
	}

	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	multiByteToWideChar := kernel32.NewProc("MultiByteToWideChar")

	ret, _, _ := multiByteToWideChar.Call(
		uintptr(cpACP),
		0,
		uintptr(unsafe.Pointer(&b[0])),
		uintptr(len(b)),
		0,
		0,
	)
	if ret == 0 {
		return string(b)
	}

	utf16 := make([]uint16, ret)
	ret, _, _ = multiByteToWideChar.Call(
		uintptr(cpACP),
		0,
		uintptr(unsafe.Pointer(&b[0])),
		uintptr(len(b)),
		uintptr(unsafe.Pointer(&utf16[0])),
		uintptr(ret),
	)
	if ret == 0 {
		return string(b)
	}
	return syscall.UTF16ToString(utf16)
}
