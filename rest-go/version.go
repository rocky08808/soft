package main

// Set at link time: go build -ldflags "-X main.version=2026.06.16.0000"
var version = "dev"

func localVersion() string {
	if version != "dev" {
		return version
	}
	if saved := readTextFile(settingsDir().Join("version.txt")); saved != "" {
		return saved
	}
	return version
}

func saveLocalVersion(v string) {
	v = stringsTrim(v)
	if v == "" {
		return
	}
	_ = osMkdirAll(settingsDir())
	_ = writeTextFile(settingsDir().Join("version.txt"), v)
}
