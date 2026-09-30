package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestResolveEffectiveTPSExpiresOnlyDatedIdleMeasurements(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*routingSnapshot)
		want   float64
	}{
		{"stale_idle", func(*routingSnapshot) {}, 100},
		{"fresh", func(s *routingSnapshot) { s.decodePerformanceAgeMs = 1000 }, 1},
		{"boundary", func(s *routingSnapshot) { s.decodePerformanceAgeMs = int32(idleDecodeMeasurementMaxAge.Milliseconds()) }, 1},
		{"unknown_age", func(s *routingSnapshot) { s.decodePerformanceAgeMs = -1 }, 1},
		{"busy", func(s *routingSnapshot) { s.wholeMacBusy = true }, 1},
		{"pending", func(s *routingSnapshot) { s.totalPending = 1 }, 1},
		{"cold", func(s *routingSnapshot) { s.modelLoaded = false }, 1},
		{"no_median", func(s *routingSnapshot) { s.fleetMedianTPS = 0 }, 80},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := routingSnapshot{modelLoaded: true, observedDecodeTPS: 1, fleetMedianTPS: 100, decodeTPS: 80,
				firstContentSnapshot: firstContentSnapshot{decodePerformanceAgeMs: int32((idleDecodeMeasurementMaxAge + time.Second).Milliseconds())}}
			tc.change(&s)
			if got := resolveEffectiveTPS(&s); got != tc.want {
				t.Fatalf("decode TPS=%v, want %v", got, tc.want)
			}
		})
	}
}

func TestIdleDecodeRankingCanRecoverWithoutQualifyingDeadline(t *testing.T) {
	r := New(testLogger())
	const model = "stale-decode-recovery"
	idle := planTestProvider(t, r, "idle", model, 0)
	busy := planTestProvider(t, r, "busy", model, 0)
	old := time.Now().Add(-idleDecodeMeasurementMaxAge - time.Minute)
	for _, p := range []*Provider{idle, busy} {
		p.mu.Lock()
		p.BackendCapacity.Slots[0].ObservedDecodeTPS = 100
		sample := p.firstContentMeasurements[model]
		sample.observedAfter, sample.decodeObservedAfter = old, old
		p.firstContentMeasurements[model] = sample
		p.mu.Unlock()
	}
	idle.mu.Lock()
	idle.BackendCapacity.Slots[0].ObservedDecodeTPS = 1
	idle.mu.Unlock()
	r.tpsRegistry.Record(model, "M3", 100)
	prior := &PendingRequest{RequestID: "decoding", Model: model, RequestedMaxTokens: 128}
	prior.MarkContentCommitted()
	busy.AddPending(prior)
	request := planTestRequest("new", 500, 128)
	request.FirstContentDeadline = time.Now().Add(10 * time.Second)
	selected, decision := r.ReserveProviderEx(model, request)
	if selected != idle {
		t.Fatalf("selected %v, want idle provider recovered through fleet estimate", selected)
	}
	if decision.FirstContent.Status != FirstContentUnknown || decision.FirstContent.Reason != "performance_age_unknown_or_stale" {
		t.Fatalf("ranking fallback invented deadline evidence: %+v", decision.FirstContent)
	}
	if idle.GetPending(request.RequestID) != request || pendingTokenBudget(request) != 628 {
		t.Fatal("recovery bypassed physical reservation")
	}
	idle.RemovePending(request.RequestID)
	busy.RemovePending(prior.RequestID)
}

func TestIdleDecodeAgeIsIndependentOfPrefillAndHeartbeat(t *testing.T) {
	r := New(testLogger())
	const model = "stale-decode-heartbeat"
	p := planTestProvider(t, r, "idle", model, 0)
	old := time.Now().Add(-idleDecodeMeasurementMaxAge - time.Minute)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 1
	sample := p.firstContentMeasurements[model]
	sample.decodeRate, sample.decodeObservedAfter = 1, old
	sample.observedAfter = time.Now()
	p.firstContentMeasurements[model] = sample
	p.mu.Unlock()
	r.tpsRegistry.Record(model, "M3", 100)
	bc := p.BackendCapacitySnapshot()
	bc.CapacitySeq = 1
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: bc}) {
		t.Fatal("heartbeat rejected")
	}
	p.mu.Lock()
	var snap routingSnapshot
	r.fillRoutingSnapshotPLocked(&snap, p, model, time.Now())
	p.mu.Unlock()
	if !staleIdleDecodeMeasurement(&snap) {
		t.Fatalf("heartbeat or fresh prefill renewed decode age: %d", snap.decodePerformanceAgeMs)
	}
	bc = p.BackendCapacitySnapshot()
	bc.CapacitySeq = 2
	bc.Slots[0].ObservedDecodeTPS = 90
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: bc}) {
		t.Fatal("changed heartbeat rejected")
	}
	p.mu.Lock()
	r.fillRoutingSnapshotPLocked(&snap, p, model, time.Now())
	p.mu.Unlock()
	if got := resolveEffectiveTPS(&snap); got != 90 {
		t.Fatalf("fresh decode rate=%v, want 90", got)
	}
}

func TestStaleIdleDecodePreservesQualifiedProfile(t *testing.T) {
	p, profile := reviewedProfileFixture(t)
	r := New(testLogger())
	now := time.Now()
	p.BackendCapacity.Slots[0].State = "idle"
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 1
	p.firstContentMeasurements = map[string]firstContentMeasurement{
		profile.ModelID: {decodeObservedAfter: now.Add(-idleDecodeMeasurementMaxAge - time.Minute)},
	}
	r.tpsRegistry.Record(profile.ModelID, p.Hardware.ChipFamily, 100)
	for _, qualified := range []bool{true, false} {
		if !qualified {
			p.Models[0].WeightHash = "unmatched-artifact"
		}
		r.mu.RLock()
		p.mu.Lock()
		var snap routingSnapshot
		r.fillRoutingSnapshotPLocked(&snap, p, profile.ModelID, now)
		p.mu.Unlock()
		r.mu.RUnlock()
		if !staleIdleDecodeMeasurement(&snap) {
			t.Fatal("fixture did not retain dated stale idle observation")
		}
		want := 100.0
		if qualified {
			want = profile.BatchCurve[0].DecodeP10TPS
		}
		if got := resolveEffectiveTPS(&snap); got != want {
			t.Fatalf("qualified=%t: decode TPS=%v, want %v", qualified, got, want)
		}
	}
}

func TestIdleDecodeAgingUsesExplicitObservationCounts(t *testing.T) {
	r := New(testLogger())
	const model = "explicit-decode-aging"
	p := planTestProvider(t, r, "idle", model, 0)
	// Keep the peer median distinct as these heartbeats add slow samples.
	for range 10 {
		r.tpsRegistry.Record(model, "M3", 100)
	}
	capacity := p.BackendCapacitySnapshot()
	capacity.Slots[0].ObservedDecodeTPS = 1
	capacity.Slots[0].PerformanceMeasurements = &protocol.PerformanceMeasurements{
		Epoch:           "engine-aging",
		IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 2000, SampleCount: 1},
		Decode: &protocol.PerformanceRateObservation{TokensPerSecond: 1, SampleCount: 3,
			SampleAgeMS: (idleDecodeMeasurementMaxAge + time.Minute).Milliseconds()},
	}
	for step := uint64(1); step <= 4; step++ {
		capacity.CapacitySeq = step
		if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
			t.Fatal("explicit measurement heartbeat rejected")
		}
		r.mu.RLock()
		p.mu.Lock()
		var snap routingSnapshot
		r.fillRoutingSnapshotPLocked(&snap, p, model, time.Now())
		p.mu.Unlock()
		r.mu.RUnlock()
		want := 100.0
		if step == 4 {
			want = 1 // A new sample count refreshes even an unchanged rate.
		}
		if got := resolveEffectiveTPS(&snap); got != want {
			t.Fatalf("step %d: decode TPS=%v, want %v", step, got, want)
		}
		capacity = p.BackendCapacitySnapshot()
		measurements := capacity.Slots[0].PerformanceMeasurements
		switch step {
		case 1:
			measurements.Decode.SampleAgeMS = 0 // A replay must not renew the sample.
		case 2:
			measurements.IsolatedPrefill.SampleCount++ // Prefill is independent.
		case 3:
			measurements.Decode.SampleCount++
		}
	}
}
