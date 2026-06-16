package main

import (
	"regexp"
	"strings"
	"unicode/utf8"
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

func parseVersion(value string) []int {
	value = stringsTrim(value)
	if value == "" {
		return []int{0}
	}
	parts := strings.Split(value, ".")
	out := make([]int, 0, len(parts))
	for _, piece := range parts {
		n := 0
		for _, r := range piece {
			if r < '0' || r > '9' {
				break
			}
			n = n*10 + int(r-'0')
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return []int{0}
	}
	return out
}

func versionIsNewer(remote, local string) bool {
	r := parseVersion(remote)
	l := parseVersion(local)
	n := len(r)
	if len(l) > n {
		n = len(l)
	}
	for i := 0; i < n; i++ {
		rv, lv := 0, 0
		if i < len(r) {
			rv = r[i]
		}
		if i < len(l) {
			lv = l[i]
		}
		if rv > lv {
			return true
		}
		if rv < lv {
			return false
		}
	}
	return false
}

func trimOutput(text string, limit int) (string, bool) {
	if limit <= 0 {
		limit = maxOutputBytes
	}
	if len(text) <= limit {
		return text, false
	}
	// Trim on UTF-8 boundary.
	b := []byte(text)
	if len(b) <= limit {
		return text, false
	}
	clipped := b[:limit]
	for len(clipped) > 0 && !utf8.Valid(clipped) {
		clipped = clipped[:len(clipped)-1]
	}
	return string(clipped) + "\n...[truncated]", true
}

func splitCommandLines(command string) []string {
	normalized := strings.ReplaceAll(command, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	normalized = stringsTrim(normalized)
	if normalized == "" {
		return nil
	}
	lines := strings.Split(normalized, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		line = stringsTrim(line)
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}
