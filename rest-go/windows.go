//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"unsafe"
)

const createNoWindow = 0x08000000

func hideChildExec(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
}

func hideExec(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
}

func machineGUID() string {
	advapi32 := syscall.NewLazyDLL("advapi32.dll")
	regOpenKeyEx := advapi32.NewProc("RegOpenKeyExW")
	regQueryValueEx := advapi32.NewProc("RegQueryValueExW")
	regCloseKey := advapi32.NewProc("RegCloseKey")

	const (
		hkeyLocalMachine = 0x80000002
		keyQueryValue    = 0x0001
		keyWow6464Key    = 0x0100
	)
	sub, err := syscall.UTF16PtrFromString(`SOFTWARE\Microsoft\Cryptography`)
	if err != nil {
		return ""
	}
	var h syscall.Handle
	r, _, _ := regOpenKeyEx.Call(
		uintptr(hkeyLocalMachine),
		uintptr(unsafe.Pointer(sub)),
		0,
		uintptr(keyQueryValue|keyWow6464Key),
		uintptr(unsafe.Pointer(&h)),
	)
	if r != 0 {
		return ""
	}
	defer regCloseKey.Call(uintptr(h))

	name, err := syscall.UTF16PtrFromString("MachineGuid")
	if err != nil {
		return ""
	}
	var buf [80]uint16
	n := uint32(len(buf) * 2)
	r, _, _ = regQueryValueEx.Call(
		uintptr(h),
		uintptr(unsafe.Pointer(name)),
		0,
		0,
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&n)),
	)
	if r != 0 {
		return ""
	}
	return normalizeMachineGUID(syscall.UTF16ToString(buf[:]))
}

func acquireSingleInstance() bool {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	createMutex := kernel32.NewProc("CreateMutexW")
	getLastError := kernel32.NewProc("GetLastError")

	name, _ := syscall.UTF16PtrFromString(restMutexName)
	_, _, _ = createMutex.Call(0, 1, uintptr(unsafe.Pointer(name)))
	errCode, _, _ := getLastError.Call()
	if errCode == 183 {
		agentLog("Another ReST instance is already running, exiting")
		return false
	}
	return true
}
