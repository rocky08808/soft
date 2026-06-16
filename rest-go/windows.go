//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"unsafe"
)

func hideExec(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000 | 0x00000200,
	}
}

func acquireSingleInstance() bool {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	createMutex := kernel32.NewProc("CreateMutexW")
	getLastError := kernel32.NewProc("GetLastError")

	name, _ := syscall.UTF16PtrFromString(`Local\ReST-TermAgent`)
	_, _, _ = createMutex.Call(0, 1, uintptr(unsafe.Pointer(name)))
	errCode, _, _ := getLastError.Call()
	if errCode == 183 {
		agentLog("Another ReST instance is already running, exiting")
		return false
	}
	return true
}
