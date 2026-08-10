package main

import (
	"fmt"
	"os"
)

func main() {
	s := resolveSettings()
	mgr := newTunnelManager(s)
	go mgr.run()
	if err := serveSOCKS(s.Listen, mgr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
