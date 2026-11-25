//go:build !windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
)

// shutdownSignals are the OS signals that ask the connector to stop. SIGTERM is
// how systemd and launchd stop a managed service; os.Interrupt covers an
// interactive Ctrl+C.
func shutdownSignals() []os.Signal {
	return []os.Signal{os.Interrupt, syscall.SIGTERM}
}

// defaultStateDir is where enrollment state is persisted when
// VACTI_CONNECTOR_STATE is unset. The install scripts set that variable
// explicitly; this is only the fallback for a hand-run binary.
//
// Linux keeps it under /var/lib (a root-run systemd service). macOS has no
// /var/lib convention, so a root-run launchd service uses the system Application
// Support tree and an unprivileged run uses the per-user one.
func defaultStateDir() string {
	if runtime.GOOS == "darwin" {
		if os.Geteuid() != 0 {
			if home, err := os.UserHomeDir(); err == nil && home != "" {
				return filepath.Join(home, "Library", "Application Support", "vacti-connector")
			}
		}
		return "/Library/Application Support/vacti-connector"
	}
	return "/var/lib/connector"
}

// runAsService is a no-op on Unix: systemd and launchd run the connector as an
// ordinary foreground process and deliver SIGTERM to stop it, so main() always
// takes the signal path.
func runAsService(_ func(context.Context) int) bool {
	return false
}
