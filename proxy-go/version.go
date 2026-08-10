package main

var version = "dev"

func localVersion() string {
	if version != "dev" {
		return version
	}
	if saved := stringsTrim(readTextFile(settingsDir().Join("version.txt"))); saved != "" {
		return saved
	}
	return version
}
