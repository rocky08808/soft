//go:build windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

const restMutexName = `Local\ReST-TermAgent`

func restUpdateInProgress() bool {
	return settingsDir().Join("ReST.update.zip").IsFile()
}

func restInstanceRunning() bool {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	openMutex := kernel32.NewProc("OpenMutexW")
	const synchronize = 0x00100000
	name, _ := syscall.UTF16PtrFromString(restMutexName)
	handle, _, _ := openMutex.Call(synchronize, 0, uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return false
	}
	_ = syscall.CloseHandle(syscall.Handle(handle))
	return true
}

func runWatchdog() {
	if restUpdateInProgress() {
		return
	}
	if restInstanceRunning() {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	if st, err := os.Stat(exe); err != nil || st.IsDir() {
		return
	}
	cmd := exec.Command(exe)
	cmd.Dir = string(settingsDir())
	hideExec(cmd)
	if err := cmd.Start(); err != nil {
		agentLog("watchdog start failed: " + err.Error())
		return
	}
	agentLog("watchdog started ReST")
}
