package registry_test

import (
	"fmt"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestIdleDecodeMeasurementStateBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name    string
		age     time.Duration
		prepare func(*production.Provider, *measurements.History, time.Time)
		want    float64
	}{
		{"stale", staleIdleDecodeAge + time.Millisecond, nil, 100},
		{"fresh", time.Second, nil, 1},
		{"current", 0, nil, 1},
		{"boundary", staleIdleDecodeAge, nil, 1},
		{"undated", staleIdleDecodeAge + time.Minute, func(_ *production.Provider, history *measurements.History, _ time.Time) {
			history.Reset()
		}, 1},
		{"future", 0, func(p *production.Provider, history *measurements.History, now time.Time) {
			history.Reset()
			history.Reconcile(p.BackendCapacity, time.Time{}, now.Add(time.Minute), 0)
		}, 1},
		{"busy", staleIdleDecodeAge + time.Minute, func(p *production.Provider, _ *measurements.History, _ time.Time) {
			p.BackendCapacity.Slots[0].NumRunning = 1
		}, 1},
		{"pending", staleIdleDecodeAge + time.Minute, func(p *production.Provider, _ *measurements.History, _ time.Time) {
			p.AddPending(&production.PendingRequest{RequestID: "held", Model: idleEvidenceModel, RequestedMaxTokens: 16})
		}, 1},
		{"cold", staleIdleDecodeAge + time.Minute, func(p *production.Provider, _ *measurements.History, _ time.Time) {
			p.BackendCapacity.Slots[0].State = "idle_shutdown"
		}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				r := newIdleEvidenceRegistry([]float64{100})
				// Missing prefill leaves the evidence gap at the new connection's
				// age, so five-minute exploration cannot mask decode expiration.
				p := r.addProvider(t, "idle", idleEvidenceFleet{staticDecode: 80, decode: 1, measurementAge: tc.age}, true, time.Now())
				if tc.prepare != nil {
					tc.prepare(p, r.histories[p.ID], time.Now())
				}
				selected, decision := r.registry.ReserveProviderEx(idleEvidenceModel, planTestRequest("new", 500, 128))
				if selected != p || decision.EffectiveTPS != tc.want {
					t.Fatalf("selected=%v decode TPS=%v, want provider and %v", selected, decision.EffectiveTPS, tc.want)
				}
			})
		})
	}
}

func TestIdleDecodeRankingCanRecoverWithoutQualifyingDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newIdleEvidenceRegistry([]float64{100})
		input := idleEvidenceFleet{staticDecode: 80, decode: 1, prefill: 2000, measurementAge: staleIdleDecodeAge + time.Minute}
		idle := r.addProvider(t, "idle", input, true, time.Now())
		input.decode = 100
		busy := r.addProvider(t, "busy", input, true, time.Now())
		// Unknown work prevents median exploration, but does not invent busy
		// work or renew the independently dated decode observation.
		idle.BackendCapacity.Slots[0].Telemetry.QueuedPrefillTokens = nil
		prior := &production.PendingRequest{RequestID: "decoding", Model: idleEvidenceModel, RequestedMaxTokens: 128}
		prior.MarkContentCommitted()
		busy.AddPending(prior)
		request := planTestRequest("new", 500, 128)
		request.FirstContentDeadline = time.Now().Add(10 * time.Second)
		selected, decision := r.registry.ReserveProviderEx(idleEvidenceModel, request)
		if selected != idle || decision.EffectiveTPS != 100 {
			t.Fatalf("selected=%v decode=%v, want recovered idle provider at 100", selected, decision.EffectiveTPS)
		}
		if decision.FirstContent.Status != production.FirstContentUnknown || decision.FirstContent.Reason != "performance_age_unknown_or_stale" {
			t.Fatalf("ranking fallback invented deadline evidence: %+v", decision.FirstContent)
		}
		if idle.GetPending(request.RequestID) != request {
			t.Fatal("recovery bypassed reservation")
		}
	})
}

func TestIdleDecodeAgeIsIndependentOfPrefillAndHeartbeat(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newIdleEvidenceRegistry(slices.Repeat([]float64{100}, 10))
		now, old := time.Now(), time.Now().Add(-staleIdleDecodeAge-time.Minute)
		p := r.addProvider(t, "idle", idleEvidenceFleet{staticDecode: 80, prefill: 2000, decode: 2}, true, now)
		history := r.histories[p.ID]
		slot := &p.BackendCapacity.Slots[0]
		slot.PerformanceMeasurements = nil
		slot.Telemetry.QueuedPrefillTokens = nil
		history.Reset()
		history.Reconcile(p.BackendCapacity, time.Time{}, old, 0)
		slot.ObservedDecodeTPS = 1
		history.Reconcile(p.BackendCapacity, old, old, 0)
		prefill := 2100.0
		slot.ObservedPrefillTPS, slot.Telemetry.IsolatedPrefillTPS = prefill, &prefill
		history.Reconcile(p.BackendCapacity, now, now, 0)
		for step, want := range []float64{100, 90} {
			capacity := p.BackendCapacitySnapshot()
			capacity.CapacitySeq = uint64(step + 1)
			if step == 1 {
				capacity.Slots[0].ObservedDecodeTPS = 90
			}
			if !r.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
				t.Fatal("heartbeat rejected")
			}
			sample, _ := history.Lookup(idleEvidenceModel)
			if !sample.ObservedAfter.Equal(now) || (step == 0 && !sample.DecodeObservedAfter.Equal(old)) {
				t.Fatalf("prefill/heartbeat renewed decode age: %+v", sample)
			}
			request := planTestRequest(fmt.Sprintf("request-%d", step), 500, 128)
			selected, decision := r.registry.ReserveProviderEx(idleEvidenceModel, request)
			if selected != p || decision.EffectiveTPS != want {
				t.Fatalf("step %d: selected=%v decode=%v, want %v", step, selected, decision.EffectiveTPS, want)
			}
			p.RemovePending(request.RequestID)
		}
	})
}

func TestIdleDecodeAgingUsesExplicitObservationCounts(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newIdleEvidenceRegistry(slices.Repeat([]float64{100}, 10))
		p := r.addProvider(t, "idle", idleEvidenceFleet{staticDecode: 80, prefill: 2000, decode: 1}, true, time.Now())
		capacity := p.BackendCapacitySnapshot()
		capacity.Slots[0].Telemetry.QueuedPrefillTokens = nil
		capacity.Slots[0].PerformanceMeasurements = &protocol.PerformanceMeasurements{
			Epoch: "engine-aging", IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 2000, SampleCount: 1},
			Decode: &protocol.PerformanceRateObservation{TokensPerSecond: 1, SampleCount: 3,
				SampleAgeMS: (staleIdleDecodeAge + time.Minute).Milliseconds()},
		}
		for step := uint64(1); step <= 4; step++ {
			capacity.CapacitySeq = step
			if !r.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
				t.Fatal("explicit measurement heartbeat rejected")
			}
			want := 100.0
			if step == 4 {
				want = 1 // A new count refreshes even an unchanged rate.
			}
			request := planTestRequest(fmt.Sprintf("request-%d", step), 500, 128)
			selected, decision := r.registry.ReserveProviderEx(idleEvidenceModel, request)
			if selected != p || decision.EffectiveTPS != want {
				t.Fatalf("step %d: selected=%v decode=%v, want %v", step, selected, decision.EffectiveTPS, want)
			}
			p.RemovePending(request.RequestID)
			capacity = p.BackendCapacitySnapshot()
			reported := capacity.Slots[0].PerformanceMeasurements
			switch step {
			case 1:
				reported.Decode.SampleAgeMS = 0 // A replay cannot renew evidence.
			case 2:
				reported.IsolatedPrefill.SampleCount++
			case 3:
				reported.Decode.SampleCount++
			}
		}
	})
}

func TestStaleIdleDecodePreservesQualifiedProfile(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		history := &measurements.History{}
		throughput := production.NewTPSRegistry()
		r, p, profile := reviewedServingProvider(t, func(deps *production.Dependencies) {
			deps.Measurements = func(string) *measurements.History { return history }
			deps.Throughput = throughput
		})
		throughput.Record(profile.ModelID, p.Hardware.ChipFamily, 100)
		p.CapacityAcceptedAt = time.Now()
		slot := &p.BackendCapacity.Slots[0]
		slot.ObservedDecodeTPS = 1
		slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64)}
		slot.PerformanceMeasurements = localRateMeasurements(2000, 1)
		history.Reconcile(p.BackendCapacity, time.Time{}, time.Now().Add(-staleIdleDecodeAge-time.Minute), 0)
		for _, qualified := range []bool{true, false} {
			want := profile.BatchCurve[0].DecodeP10TPS
			if !qualified {
				p.Models[0].WeightHash = "unmatched-artifact"
				want = 100
			}
			request := planTestRequest(fmt.Sprintf("qualified-%t", qualified), 500, 128)
			selected, decision := r.ReserveProviderEx(profile.ModelID, request)
			if selected != p || decision.EffectiveTPS != want {
				t.Fatalf("qualified=%t: selected=%v decode=%v, want %v", qualified, selected, decision.EffectiveTPS, want)
			}
			if got := request.FirstContentExplored(); got == qualified {
				t.Fatalf("qualified=%t: explored=%t, want only actual median pricing tagged", qualified, got)
			}
			p.RemovePending(request.RequestID)
		}
	})
}

func TestStaleIdleDecodeRetainsRegistrationFallbackAndTokenReservation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newIdleEvidenceRegistry(nil)
		p := r.addProvider(t, "idle", idleEvidenceFleet{staticDecode: 80, decode: 1, measurementAge: staleIdleDecodeAge + time.Minute}, true, time.Now())
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 628
		request := planTestRequest("new", 500, 128)
		selected, decision := r.registry.ReserveProviderEx(idleEvidenceModel, request)
		if selected != p || decision.EffectiveTPS != 80 || p.GetPending(request.RequestID) != request {
			t.Fatalf("stale fallback did not reserve at registration rate: selected=%v decision=%+v", selected, decision)
		}
		if candidates, rejected, _ := r.registry.QuickCapacityCheck(idleEvidenceModel, 1, 1, production.RequestTraits{}); candidates != 0 || rejected != 1 {
			t.Fatalf("reservation did not consume all 628 tokens: candidates=%d rejected=%d", candidates, rejected)
		}
		p.RemovePending(request.RequestID)
		if candidates, rejected, _ := r.registry.QuickCapacityCheck(idleEvidenceModel, 1, 1, production.RequestTraits{}); candidates != 1 || rejected != 0 {
			t.Fatalf("retired reservation retained tokens: candidates=%d rejected=%d", candidates, rejected)
		}
	})
}

func TestStaleIdleDecodeShadowUsesSameRateAsRanking(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, production.TTFTAdmissionShadow)
	synctest.Test(t, func(t *testing.T) {
		r := newIdleEvidenceRegistry([]float64{100})
		p := r.addProvider(t, "idle", idleEvidenceFleet{staticDecode: 80, decode: 1, measurementAge: staleIdleDecodeAge + time.Minute}, true, time.Now())
		selected, decision := r.registry.ReserveProviderEx(idleEvidenceModel, planTestRequest("new", 500, 128))
		if selected != p || decision.EffectiveTPS != 100 || !decision.ShadowEvaluated || decision.ShadowEstimateMs != decision.RawTTFTMs {
			t.Fatalf("shadow retained stale decode after live ranking recovered: %+v", decision)
		}
	})
}
