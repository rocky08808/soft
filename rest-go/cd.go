package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	driveOnlyRE     = regexp.MustCompile(`^[a-zA-Z]:$`)
	cmdDriveRE      = regexp.MustCompile(`^([a-zA-Z]:)\s*$`)
	psCdRE          = regexp.MustCompile(`(?i)^(cd|set-location|sl)\s+(.+)$`)
	cmdCdDRE        = regexp.MustCompile(`(?i)^cd\s+/d\s+(.+)$`)
	cmdCdRE         = regexp.MustCompile(`(?i)^cd\s+(.+)$`)
	cmdChdirRE      = regexp.MustCompile(`(?i)^chdir\s+(.+)$`)
)

var sessionCWD string

func defaultCWD() string {
	if sessionCWD != "" {
		return sessionCWD
	}
	for _, candidate := range []string{
		os.Getenv("USERPROFILE"),
		os.Getenv("HOMEDRIVE") + os.Getenv("HOMEPATH"),
	} {
		if candidate == "" {
			continue
		}
		if st, err := os.Stat(candidate); err == nil && st.IsDir() {
			abs, err := filepath.Abs(candidate)
			if err == nil {
				sessionCWD = abs
				return sessionCWD
			}
		}
	}
	drive := os.Getenv("SystemDrive")
	if drive == "" {
		drive = "C:"
	}
	sessionCWD = drive + `\`
	return sessionCWD
}

func setSessionCWD(path string) {
	abs, err := filepath.Abs(path)
	if err == nil {
		sessionCWD = abs
	}
}

func resolveCDTarget(base, target string) string {
	raw := stringsTrim(target)
	raw = strings.Trim(raw, `"'`)
	if raw == "" {
		return base
	}
	if driveOnlyRE.MatchString(raw) {
		root := strings.ToUpper(raw[:1]) + `:\`
		if st, err := os.Stat(root); err == nil && st.IsDir() {
			return root
		}
		return ""
	}
	path := raw
	if !filepath.IsAbs(path) {
		path = filepath.Join(base, path)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return ""
	}
	st, err := os.Stat(abs)
	if err != nil || !st.IsDir() {
		return ""
	}
	return abs
}

func resolveInitialWorkdir(cwd string) string {
	cwd = stringsTrim(cwd)
	if cwd != "" {
		if st, err := os.Stat(cwd); err == nil && st.IsDir() {
			setSessionCWD(cwd)
		}
	}
	return defaultCWD()
}

func applyCDCommand(command, shell, current string) (newCWD string, handled bool, cdError string) {
	cmd := stringsTrim(command)
	if cmd == "" || strings.Contains(cmd, "\n") || strings.Contains(cmd, "\r") {
		return "", false, ""
	}

	lower := strings.ToLower(cmd)
	if lower == "pwd" || lower == "cwd" || lower == "echo %cd%" {
		return current, true, ""
	}

	if shell == "powershell" {
		if lower == "get-location" || lower == "gl" {
			return current, true, ""
		}
		if lower == "cd" {
			home := os.Getenv("USERPROFILE")
			if home == "" {
				home = current
			}
			return home, true, ""
		}
		if m := psCdRE.FindStringSubmatch(cmd); m != nil {
			target := resolveCDTarget(current, m[2])
			if target != "" {
				return target, true, ""
			}
			return "", true, "Cannot find path because it does not exist.\n"
		}
		return "", false, ""
	}

	if lower == "cd" {
		home := os.Getenv("USERPROFILE")
		if home == "" {
			home = current
		}
		return home, true, ""
	}

	if m := cmdDriveRE.FindStringSubmatch(cmd); m != nil {
		root := strings.ToUpper(m[1]) + `\`
		if st, err := os.Stat(root); err == nil && st.IsDir() {
			return root, true, ""
		}
		return "", true, "The system cannot find the drive specified.\n"
	}

	var targetArg string
	switch {
	case cmdCdDRE.MatchString(cmd):
		targetArg = cmdCdDRE.FindStringSubmatch(cmd)[1]
	case cmdCdRE.MatchString(cmd):
		targetArg = cmdCdRE.FindStringSubmatch(cmd)[1]
	case cmdChdirRE.MatchString(cmd):
		targetArg = cmdChdirRE.FindStringSubmatch(cmd)[1]
	default:
		return "", false, ""
	}

	target := resolveCDTarget(current, targetArg)
	if target != "" {
		return target, true, ""
	}
	return "", true, "The system cannot find the path specified.\n"
}
