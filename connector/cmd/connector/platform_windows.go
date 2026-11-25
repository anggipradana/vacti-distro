//go:build windows

package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
)

// serviceName must match the name the installer registers with the SCM
// (install-connector.ps1: `sc.exe create VactiConnector ...`).
const serviceName = "VactiConnector"

// shutdownSignals: Windows has no SIGTERM. os.Interrupt covers an interactive
// Ctrl+C for a console run. When the process runs under the SCM, runAsService
// handles Stop/Shutdown directly and this signal path is not used.
func shutdownSignals() []os.Signal {
	return []os.Signal{os.Interrupt}
}

// defaultStateDir is the fallback enrollment-state location when
// VACTI_CONNECTOR_STATE is unset. The installer sets the variable in the service
// definition; this matches the ProgramData path it uses.
func defaultStateDir() string {
	base := os.Getenv("ProgramData")
	if base == "" {
		base = `C:\ProgramData`
	}
	return filepath.Join(base, "Vacti", "connector")
}

// runAsService detects whether the process was started by the Windows Service
// Control Manager. If so it runs the connector under an SCM handler that maps
// Stop/Shutdown/Pause/Continue onto context lifecycle, and returns true. For an
// interactive run it returns false so main() uses the signal path.
func runAsService(run func(context.Context) int) bool {
	isSvc, err := svc.IsWindowsService()
	if err != nil {
		log.Printf("could not determine Windows service status: %v", err)
		return false
	}
	if !isSvc {
		return false
	}
	if err := svc.Run(serviceName, &connectorService{run: run}); err != nil {
		log.Printf("service handler failed: %v", err)
	}
	return true
}

// connectorService adapts run() to the SCM svc.Handler interface.
type connectorService struct {
	run func(context.Context) int
}

// Execute is the SCM entry point. It starts run() in a goroutine and translates
// control requests into context cancellation; Pause cancels the outbound session
// (grants drop) and Continue re-establishes it.
func (m *connectorService) Execute(_ []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	const accepted = svc.AcceptStop | svc.AcceptShutdown | svc.AcceptPauseAndContinue
	s <- svc.Status{State: svc.StartPending}

	ctx, cancel := context.WithCancel(context.Background())
	defer func() { cancel() }()

	done := make(chan int, 1)
	go func() { done <- m.run(ctx) }()

	s <- svc.Status{State: svc.Running, Accepts: accepted}
	for {
		select {
		case code := <-done:
			// run() returned on its own: revoked access (code 3), a startup
			// failure (code 1) or a clean stop. Report the exit code to the SCM.
			s <- svc.Status{State: svc.StopPending}
			return false, uint32(code)

		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				s <- c.CurrentStatus

			case svc.Stop, svc.Shutdown:
				s <- svc.Status{State: svc.StopPending}
				cancel()
				// Give the session a bounded window to close gracefully.
				if done != nil {
					select {
					case <-done:
					case <-time.After(20 * time.Second):
					}
				}
				return false, 0

			case svc.Pause:
				cancel()
				// Disable the done case while paused so an in-flight completion
				// of the cancelled run does not self-stop the service.
				done = nil
				s <- svc.Status{State: svc.Paused, Accepts: accepted}

			case svc.Continue:
				ctx, cancel = context.WithCancel(context.Background())
				done = make(chan int, 1)
				go func() { done <- m.run(ctx) }()
				s <- svc.Status{State: svc.Running, Accepts: accepted}

			default:
				log.Printf("unexpected service control request #%d", c.Cmd)
			}
		}
	}
}
