package main

import (
	"regexp"
	"strings"
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
