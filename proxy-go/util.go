package main

import (
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

func stringsTrim(s string) string { return strings.TrimSpace(s) }

var deviceIDSanitize = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

func sanitizeDeviceID(value string) string {
	cleaned := deviceIDSanitize.ReplaceAllString(stringsTrim(value), "-")
	cleaned = strings.Trim(cleaned, "-_")
	if cleaned == "" {
		return "PC-UNKNOWN"
	}
	if len(cleaned) > 48 {
		return cleaned[:48]
	}
	return cleaned
}

func fetchPublicIP() string {
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Get("https://ifconfig.me/ip")
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return ""
	}
	return stringsTrim(string(b))
}
