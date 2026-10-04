package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestMimoCalibrationWorkloadConcurrencyIsBoundedAndLegacyOptional(t *testing.T) {
	for _, tc := range []struct {
		width      int
		contention string
		valid      bool
	}{{0, "isolated", true}, {1, "isolated", true}, {4, "contended", true},
		{4, "isolated", false}, {-1, "contended", false}, {65, "contended", false}} {
		p := &protocol.PerformanceMeasurements{Epoch: "loaded-engine", WorkloadBuckets: []protocol.PerformanceWorkloadBucket{{
			Phase: "decode", PromptTokenBucket: 1024, ContextTokenBucket: 1024, CacheState: "cold",
			Contention: tc.contention, ConcurrentRequests: tc.width,
			Observation: protocol.PerformanceRateObservation{TokensPerSecond: 60, SampleCount: 1},
		}}}
		capacityvalue.ClampPerformanceMeasurements(p)
		if (len(p.WorkloadBuckets) == 1) != tc.valid {
			t.Fatalf("width=%d contention=%s: %+v", tc.width, tc.contention, p)
		}
	}
}

// Synthetic capacity frames exercise the ordinary routing contract; no
// provider identity or hardware qualification is promoted by this fixture.
func TestMimoCalibrationHeartbeatRestoresFreshFeasibleRouting(t *testing.T) {
	now := time.Now()
	history := &measurements.History{}
	r := production.NewWithDependencies(testLogger(), production.Dependencies{Measurements: func(string) *measurements.History { return history }})
	model := "mimo-calibration-fixture"
	p := makeTokenBudgetProvider(t, r, "idle-m5", model, 60, 0, 65536, 60)
	f := observedForecastFixture{r: r, p: p, history: history}
	p.Mu().Lock()
	p.CapacityAcceptedAt = now
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	slot.ObservedPrefillTPS = 6.1
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64)}
	slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{Epoch: "loaded-engine",
		IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 6.1, SampleCount: 1, SampleAgeMS: 1_200_000},
		Decode:          &protocol.PerformanceRateObservation{TokensPerSecond: 60, SampleCount: 1, SampleAgeMS: 1_200_000}}
	history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, time.Second)
	pr := &production.PendingRequest{RequestID: "after-calibration", Model: model, EstimatedPromptTokens: 512,
		RequestedMaxTokens: 128, FirstContentDeadline: now.Add(9 * time.Second), RequireFreshFeasible: true}
	request := forecast.Request{PromptTokens: 512, UpperBoundTokens: 512, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: pr.FirstContentDeadline, RequireFreshFeasible: true}
	before := forecast.Evaluate(f.evidence(now), request, now).Estimate
	if before.Status == forecast.Feasible {
		t.Fatal("expired prefill evidence should not satisfy fresh feasibility")
	}
	// Actual probe receipts increment both phase counts, even if decode TPS
	// happens to be unchanged. A heartbeat alone does not perform this update.
	slot.ObservedPrefillTPS = 900
	slot.PerformanceMeasurements.IsolatedPrefill = &protocol.PerformanceRateObservation{TokensPerSecond: 900, SampleCount: 3}
	slot.PerformanceMeasurements.Decode = &protocol.PerformanceRateObservation{TokensPerSecond: 60, SampleCount: 3}
	history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, time.Second)
	after := forecast.Evaluate(f.evidence(now), request, now).Estimate
	p.Mu().Unlock()
	if after.Status != forecast.Feasible {
		t.Fatalf("completed calibration did not restore feasibility: %+v", after)
	}
	selected, _ := r.ReserveProviderEx(model, pr)
	if selected != p {
		t.Fatalf("fresh idle provider was not used: selected=%v", selected)
	}
	if got := p.GetPending(pr.RequestID); got == nil {
		t.Fatal("routing did not reserve the actual consumer request")
	}
}

func TestMimoCalibrationUsesOnlyFreshMatchingColdPrefillCells(t *testing.T) {
	now := time.Now()
	m := &protocol.PerformanceMeasurements{Epoch: "loaded-engine", WorkloadBuckets: []protocol.PerformanceWorkloadBucket{{
		Phase: "prefill", PromptTokenBucket: 4096, ContextTokenBucket: 4096,
		CacheState: "cold", Contention: "isolated", ConcurrentRequests: 1,
		Observation: protocol.PerformanceRateObservation{TokensPerSecond: 100, SampleCount: 2},
	}}}
	rate := func(tokens int, at time.Time) float64 {
		return measurements.CapPrefillByWorkload(900, tokens, measurements.SnapshotWorkloadRates(m, now, time.Second), at, forecast.PerformanceFreshness)
	}
	if rate(4096, now) != 100 || rate(512, now) != 900 || rate(16384, now) != 900 || rate(4096, now.Add(121*time.Second)) != 900 {
		t.Fatal("shape rate crossed prompt domain or remained fresh after expiry")
	}
	for _, modify := range []func(*protocol.PerformanceWorkloadBucket){
		func(b *protocol.PerformanceWorkloadBucket) { b.CacheState = "reused" },
		func(b *protocol.PerformanceWorkloadBucket) { b.Contention = "contended" },
		func(b *protocol.PerformanceWorkloadBucket) { b.ConcurrentRequests = 4 },
		func(b *protocol.PerformanceWorkloadBucket) { b.OtherModelActivity = true },
	} {
		original := m.WorkloadBuckets[0]
		modify(&m.WorkloadBuckets[0])
		if rate(4096, now) != 900 {
			t.Fatal("cache/competing work established a solo prefill rate")
		}
		m.WorkloadBuckets[0] = original
	}
	pr := forecast.Request{PromptTokens: 4096, UpperBoundTokens: 4096, Incoming: performance.IncomingWork{RequestedMaxTokens: 32}, Deadline: now.Add(9 * time.Second)}
	c := measuredFirstContentEvidence(now)
	c.WorkloadRates = measurements.SnapshotWorkloadRates(m, now, time.Second)
	estimate := forecast.Evaluate(c, pr, now).Estimate
	if estimate.Status != forecast.PredictedLate {
		t.Fatalf("fresh 4k measurement failed to constrain admission: %+v", estimate)
	}
}
