package main

import "fmt"

func main() {
	s := resolveSettings()
	if !acquireSingleInstance() {
		return
	}
	if version == "dev" {
		fmt.Println("Server:", s.Server)
		fmt.Println("Device:", s.DeviceID)
	}
	newAgent(s).run()
}
