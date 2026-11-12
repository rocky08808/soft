//go:build !windows

package main

func machineGUID() string { return "" }

func acquireSingleInstance() bool { return true }

func runWatchdog() {}
