package main

import (
	"fmt"
	"strconv"
	"strings"
)

func parseListenHostPort(listen string) (host, port string, err error) {
	listen = stringsTrim(listen)
	if listen == "" {
		return "127.0.0.1", "1080", nil
	}
	if strings.HasPrefix(listen, "[") {
		if i := strings.LastIndex(listen, "]:"); i >= 0 {
			return listen[1:i], listen[i+2:], nil
		}
	}
	if i := strings.LastIndex(listen, ":"); i >= 0 {
		return listen[:i], listen[i+1:], nil
	}
	return listen, "1080", nil
}

func httpProxyListenForSOCKS(socksListen string) string {
	_, port, err := parseListenHostPort(socksListen)
	if err != nil || port == "1080" || port == "8080" {
		return "127.0.0.1:8080"
	}
	if p, err := strconv.Atoi(port); err == nil && p > 0 {
		return fmt.Sprintf("127.0.0.1:%d", p+1)
	}
	return "127.0.0.1:8080"
}
