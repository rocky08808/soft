package main

import (
	"os"
	"path/filepath"
)

type pathRef string

func (p pathRef) String() string { return string(p) }
func (p pathRef) Join(parts ...string) pathRef {
	return pathRef(filepath.Join(append([]string{string(p)}, parts...)...))
}
func (p pathRef) IsFile() bool {
	st, err := os.Stat(string(p))
	return err == nil && !st.IsDir()
}
func (p pathRef) IsDir() bool {
	st, err := os.Stat(string(p))
	return err == nil && st.IsDir()
}

func settingsDir() pathRef {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local")
	}
	return pathRef(filepath.Join(base, "ReST"))
}

func deviceIDPath() pathRef  { return settingsDir().Join("device.id") }
func logPath() pathRef       { return settingsDir().Join("term-agent.log") }
func configPathLocal() pathRef { return settingsDir().Join("agent.config.json") }

func osMkdirAll(dir pathRef) error {
	return os.MkdirAll(string(dir), 0o755)
}

func readTextFile(path pathRef) string {
	b, err := os.ReadFile(string(path))
	if err != nil {
		return ""
	}
	return string(b)
}

func writeTextFile(path pathRef, text string) error {
	return os.WriteFile(string(path), []byte(text), 0o644)
}
