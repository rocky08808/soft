//go:build !windows

package main

type winProxyBackup struct {
	active bool
}

func applyWinProxy(listen string) (winProxyBackup, error) {
	return winProxyBackup{}, nil
}

func restoreWinProxy(backup winProxyBackup) error {
	return nil
}
