package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
	"testing"
	"time"
)

func measuredFirstContentEvidence(now time.Time) forecast.Evidence {
	return forecast.Evidence{Calibration: performance.CalibrationEvidence{
		CapacityAgeMS: 0, PerformanceAgeMS: 0, IsolatedPrefillTPS: 2000, IsolatedInitialized: true, HasCapacity: true, ModelLoaded: true,
	}, CapacityAcceptedAt: now, PrefillTPS: 2000, DecodeTPS: 100, ObservedDecodeTPS: 100,
		Workload: forecast.Workload{WholeMacKnown: true}}
}

type observedForecastFixture struct {
	r       *production.Registry
	p       *production.Provider
	history *measurements.History
}

func newObservedForecastFixture(t *testing.T, id, model string, decode float64) *observedForecastFixture {
	t.Helper()
	f := &observedForecastFixture{history: &measurements.History{}}
	f.r = production.NewWithDependencies(testLogger(), production.Dependencies{
		Measurements: func(string) *measurements.History { return f.history },
	})
	f.p = makeSchedulerProvider(t, f.r, id, model, decode)
	return f
}

func (f *observedForecastFixture) fresh(rate float64) {
	f.p.Mu().Lock()
	defer f.p.Mu().Unlock()
	now := time.Now()
	f.p.CapacityAcceptedAt = now
	f.p.PrefillTPS = rate
	slot := &f.p.BackendCapacity.Slots[0]
	slot.State, slot.ObservedPrefillTPS = "idle", rate
	slot.ObservedDecodeTPS = 100
	initialized := true
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64), IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
	slot.PerformanceMeasurements = localRateMeasurements(rate, slot.ObservedDecodeTPS)
	f.history.Reconcile(f.p.BackendCapacity, f.p.CapacityAcceptedAt, now, 0)
}

// Inputs are retained from this fixture's heartbeat and local reservations;
// the production work builder and measurement history perform the calculations.
func (f *observedForecastFixture) evidence(now time.Time, pending ...forecast.PendingWork) forecast.Evidence {
	p := f.p
	slot := p.BackendCapacity.Slots[0]
	sample, _ := f.history.Lookup(slot.Model)
	age := func(at time.Time) int32 {
		if at.IsZero() {
			return -1
		}
		return selection.HeartbeatAgeMs(now, at)
	}
	decode := quality.DecodeFallback(p.DecodeTPS, p.Hardware)
	prefill := quality.PrefillFallback(p.PrefillTPS, decode, 12)
	b := forecast.NewWorkBuilder(slot.Model, p.BackendCapacity, p.CapacityAcceptedAt, decode, prefill, false)
	for i := range p.BackendCapacity.Slots {
		b.BeginSlot(i)
		for _, work := range pending {
			b.Pending(work)
		}
		b.EndSlot()
	}
	for _, work := range pending {
		b.UnreportedPending(work)
	}
	e := forecast.Evidence{CapacityAcceptedAt: p.CapacityAcceptedAt,
		PrefillTPS: slot.ObservedPrefillTPS, DecodeTPS: slot.ObservedDecodeTPS, ObservedDecodeTPS: slot.ObservedDecodeTPS,
		Workload: b.Finish(), Calibration: performance.CalibrationEvidence{
			HasCapacity: true, ModelLoaded: slot.State == "idle" || slot.State == "running",
			CapacityAgeMS: age(p.CapacityAcceptedAt), PerformanceAgeMS: max(age(sample.ObservedAfter), age(sample.DecodeObservedAfter)),
		}}
	if slot.Telemetry != nil {
		if rate := slot.Telemetry.IsolatedPrefillTPS; rate != nil {
			e.Calibration.IsolatedPrefillTPS = *rate
		}
		e.Calibration.IsolatedInitialized = slot.Telemetry.EWMAInitialized != nil && *slot.Telemetry.EWMAInitialized
		if m := slot.PerformanceMeasurements; m != nil {
			e.Calibration.IsolatedInitialized = capacityvalue.ValidPerformanceObservation(m.IsolatedPrefill)
			if e.Calibration.IsolatedInitialized {
				e.Calibration.IsolatedPrefillTPS = m.IsolatedPrefill.TokensPerSecond
			}
		}
	}
	return e
}

func legacyRateCapacity(model string, prefill, decode float64) *protocol.BackendCapacity {
	initialized := true
	return &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
		Model: model, State: "idle", ObservedDecodeTPS: decode,
		Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &prefill, EWMAInitialized: &initialized},
	}}}
}
