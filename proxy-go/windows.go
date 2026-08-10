//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"unsafe"
)

const proxyMutexName = `Local\ReProxy-Agent`
const createNoWindow = 0x08000000

func hideExec(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
}

func acquireSingleInstance() bool {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	createMutex := kernel32.NewProc("CreateMutexW")
	getLastError := kernel32.NewProc("GetLastError")

	name, _ := syscall.UTF16PtrFromString(proxyMutexName)
	_, _, _ = createMutex.Call(0, 1, uintptr(unsafe.Pointer(name)))
	errCode, _, _ := getLastError.Call()
	if errCode == 183 {
		agentLog("Another ReProxy instance is already running, exiting")
		return false
	}
	return true
}
