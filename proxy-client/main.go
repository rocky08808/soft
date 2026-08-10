package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if len(os.Args) == 1 {
		runWebUI()
		return
	}
	runCLI()
}

func runCLI() {
	s, err := resolveSettings()
	if err != nil {
		printUsage()
		fatal(err)
	}

	fmt.Printf("ProxyClient SOCKS5 on %s\n", s.Listen)
	fmt.Printf("Remote device: %s\n", s.DeviceID)
	fmt.Printf("Server: %s\n", s.Server)
	fmt.Println("Set browser SOCKS5, then open https://ifconfig.me")
	fmt.Println("Press Ctrl+C to stop")
	fmt.Println()

	mgr := newTunnelManager(s)
	go mgr.run()

	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
		<-ch
		fmt.Println("\nStopping...")
		os.Exit(0)
	}()

	if err := serveSOCKS(s.Listen, mgr); err != nil {
		fatal(err)
	}
}
