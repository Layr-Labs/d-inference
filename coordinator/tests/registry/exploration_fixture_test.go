package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
	"time"
)

type explorationFixture struct {
	registry        *production.Registry
	qualified, idle *production.Provider
	history         *measurements.History
	now             time.Time
}

func newExplorationPair(t *testing.T, model string, connectionAge time.Duration, gap func(*production.Provider, *measurements.History, time.Time), configure ...func(*production.Dependencies)) *explorationFixture {
	t.Helper()
	f := &explorationFixture{now: time.Now(), history: &measurements.History{}}
	qualifiedHistory := &measurements.History{}
	deps := production.Dependencies{
		Measurements: func(id string) *measurements.History {
			if id == "idle" {
				return f.history
			}
			return qualifiedHistory
		},
		ConnectionOrigin: func(id string, at time.Time) *connectiontime.Origin {
			if id == "idle" {
				return connectiontime.New(f.now.Add(-connectionAge))
			}
			return connectiontime.New(at)
		},
	}
	for _, setup := range configure {
		setup(&deps)
	}
	f.registry = production.NewWithDependencies(testLogger(), deps)
	for _, entry := range []struct {
		id      string
		history *measurements.History
	}{{"qualified", qualifiedHistory}, {"idle", f.history}} {
		p := makeTokenBudgetProvider(t, f.registry, entry.id, model, 100, 0, 1_000_000, 80)
		p.Mu().Lock()
		now := time.Now()
		p.CapacityAcceptedAt = now
		zero, initialized, rate := int64(0), true, 1200.0
		p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero, IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
		p.BackendCapacity.Slots[0].PerformanceMeasurements = localRateMeasurements(rate, 80)
		entry.history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
		p.Mu().Unlock()
		if entry.id == "idle" {
			f.idle = p
		} else {
			f.qualified = p
		}
	}
	f.idle.Mu().Lock()
	f.idle.PrefillTPS = 20_000
	if gap != nil {
		gap(f.idle, f.history, f.now)
	}
	f.idle.Mu().Unlock()
	return f
}

func deadlineRequest() *production.PendingRequest {
	pr := &production.PendingRequest{RequestID: "request", EstimatedPromptTokens: 500, RequestedMaxTokens: 128}
	pr.FirstContentDeadline = time.Now().Add(10 * time.Second)
	return pr
}
