package dispatch_test

import (
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/providerframe"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRaceClosedErrorKeepsSurvivingAttempt(t *testing.T) {
	dispatch.CheckRaceClosedErrorKeepsSurvivingAttempt(t, raceTerminalPublisher)
}

func TestRunRaceQueuedErrorKeepsSurvivingAttempt(t *testing.T) {
	dispatch.CheckRunRaceQueuedErrorKeepsSurvivingAttempt(t, raceTerminalPublisher)
}

func TestRaceChunkWinnerStillCancelsLoser(t *testing.T) {
	dispatch.CheckRaceChunkWinnerStillCancelsLoser(t, raceTerminalPublisher)
}

// Exercise the real provider terminal, including pending removal and channel
// publication order. These live, unprofiled attempts do not park settlement;
// dispatch still uses its actual attempt, registry and accounting services.
func raceTerminalPublisher(reg *registry.Registry, attempts attempt.Service, logger *slog.Logger) func(*registry.Provider, *protocol.InferenceErrorMessage) {
	frames := providerframe.New(providerframe.Dependencies{
		Registry:        func() providerframe.Registry { return reg },
		Logger:          func() *slog.Logger { return logger },
		Attempts:        func() attempt.Service { return attempts },
		ClaimSettlement: func(string) *registry.PendingRequest { return nil },
		Metrics:         terminalMetrics{},
		Cache: providerframe.CacheTelemetry{
			Terminal: func(*registry.PendingRequest, protocol.UsageInfo, bool, bool) bool { return false },
		},
	})
	return func(provider *registry.Provider, msg *protocol.InferenceErrorMessage) {
		frames.Error(provider.ID, provider, msg)
	}
}

type terminalMetrics struct{}

func (terminalMetrics) Incr(string, []string)               {}
func (terminalMetrics) Count(string, int64, []string)       {}
func (terminalMetrics) Histogram(string, float64, []string) {}
