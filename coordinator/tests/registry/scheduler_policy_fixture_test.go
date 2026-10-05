package registry_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func newSchedulerPolicyRegistry() (*production.Registry, *measurements.History) {
	history := &measurements.History{}
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		Measurements: func(string) *measurements.History { return history },
	})
	return reg, history
}

func setSchedulerPolicyTelemetry(p *production.Provider, history *measurements.History, rate float64) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	now := time.Now()
	p.CapacityAcceptedAt = now
	p.PrefillTPS = rate
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	slot.ObservedPrefillTPS = rate
	slot.ObservedDecodeTPS = 100
	slot.Telemetry = &protocol.SlotTelemetry{
		QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64),
		IsolatedPrefillTPS: &rate, EWMAInitialized: new(bool),
	}
	*slot.Telemetry.EWMAInitialized = true
	slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{Epoch: "fixture-local",
		IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: rate, SampleCount: 1},
		Decode:          &protocol.PerformanceRateObservation{TokensPerSecond: slot.ObservedDecodeTPS, SampleCount: 1}}
	// Local sampling has no transport handoff; use the actual retained history.
	history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
}
