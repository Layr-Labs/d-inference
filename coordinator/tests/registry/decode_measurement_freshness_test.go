package registry_test

import (
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

const (
	freshnessModel  = "decode-freshness-model"
	freshnessMedian = 100.0
	freshnessStatic = 80.0
)

var staleIdleDecode = performance.IdleDecodeMaxAge + time.Minute

// staleDecodeRates has an observed decode rate below both the fleet median and
// the registration rate, so each result shows which source was used.
func staleDecodeRates(idleAge time.Duration) performance.Rates {
	return performance.Rates{ObservedDecode: 1, FleetMedian: freshnessMedian, StaticDecode: freshnessStatic, IdleDecodeAge: idleAge}
}

func TestEffectiveDecodeExpiresOnlyOldIdleObservations(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*performance.Rates)
		want   float64
	}{
		{"stale_idle", func(*performance.Rates) {}, freshnessMedian},
		{"fresh", func(r *performance.Rates) { r.IdleDecodeAge = time.Second }, 1},
		{"boundary", func(r *performance.Rates) { r.IdleDecodeAge = performance.IdleDecodeMaxAge }, 1},
		{"not_idle_or_undated", func(r *performance.Rates) { r.IdleDecodeAge = 0 }, 1},
		{"no_median", func(r *performance.Rates) { r.FleetMedian = 0 }, freshnessStatic},
		{"explored", func(r *performance.Rates) { r.ExploredDecode = 52 }, 52},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rates := staleDecodeRates(staleIdleDecode)
			tc.change(&rates)
			if got := rates.EffectiveDecode(0); got != tc.want {
				t.Fatalf("decode TPS=%v, want %v", got, tc.want)
			}
		})
	}
}

func TestStaleIdleDecodePreservesQualifiedProfile(t *testing.T) {
	rates := staleDecodeRates(staleIdleDecode)
	rates.Profile = &performance.Profile{MaxConcurrency: 4,
		BatchCurve: []performance.BatchPoint{{Width: 1, DecodeP10TPS: 35, PrefillTPS: 900}}}
	if got := rates.EffectiveDecode(0); got != 35 {
		t.Fatalf("decode TPS=%v, want the reviewed profile point 35", got)
	}
	rates.Profile = nil
	if got := rates.EffectiveDecode(0); got != freshnessMedian {
		t.Fatalf("unmatched configuration decode TPS=%v, want the fleet median %v", got, freshnessMedian)
	}
}

// The decode-floor projection keeps the provider's own rate chain.
func TestStaleIdleDecodeDoesNotEnterProjectedDecode(t *testing.T) {
	if got := staleDecodeRates(staleIdleDecode).ProjectedDecode(0, 0, true); got != 1 {
		t.Fatalf("projected decode %v, want the observed EWMA 1", got)
	}
}

// freshnessRegistry is a registry whose fleet decode median for
// freshnessModel comes only from the given samples. It keeps each provider's
// measurement history.
func freshnessRegistry(fleetSamples ...float64) *idleEvidenceRegistry {
	throughput := production.NewTPSRegistry()
	for _, tps := range fleetSamples {
		throughput.Record(freshnessModel, testRegisterMessage().Hardware.ChipFamily, tps)
	}
	r := &idleEvidenceRegistry{histories: map[string]*measurements.History{}}
	r.registry = production.NewWithDependencies(testLogger(), production.Dependencies{
		Throughput: throughput,
		Measurements: func(id string) *measurements.History {
			history := &measurements.History{}
			r.histories[id] = history
			return history
		},
	})
	return r
}

// freshnessProvider registers an idle provider whose decode EWMA is decode and
// whose explicit decode observation is decodeAge old. Its isolated prefill
// observation is fresh. Its telemetry omits queued-prefill counters, so
// whole-Mac work is unknown and evidence exploration does not price it; only
// decode aging can replace its observed rate.
func freshnessProvider(t *testing.T, r *idleEvidenceRegistry, id string, decode float64, decodeAge time.Duration) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r.registry, id, freshnessModel, freshnessStatic)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	now := time.Now()
	p.CapacityAcceptedAt = now
	slot := &p.BackendCapacity.Slots[0]
	slot.State, slot.ObservedDecodeTPS = "idle", decode
	slot.Telemetry = &protocol.SlotTelemetry{}
	slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{
		Epoch:           "decode-freshness",
		IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 2000, SampleCount: 1},
		Decode: &protocol.PerformanceRateObservation{TokensPerSecond: decode, SampleCount: 1,
			SampleAgeMS: decodeAge.Milliseconds()},
	}
	r.histories[id].Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
	return p
}

func freshnessRequest(id string) *production.PendingRequest {
	return &production.PendingRequest{RequestID: id, Model: freshnessModel, EstimatedPromptTokens: 500, RequestedMaxTokens: 128}
}

// soleFreshnessDecode reserves one request on the only provider and returns
// the decode rate the decision priced it at.
func soleFreshnessDecode(t *testing.T, r *idleEvidenceRegistry, p *production.Provider, id string) float64 {
	t.Helper()
	request := freshnessRequest(id)
	selected, decision := r.registry.ReserveProviderEx(freshnessModel, request)
	if selected != p {
		t.Fatalf("%s: the only provider was not selected: %+v", id, decision)
	}
	p.RemovePending(request.RequestID)
	return decision.EffectiveTPS
}

func TestIdleDecodeAgingAppliesOnlyToDatedIdleProviders(t *testing.T) {
	for _, tc := range []struct {
		name   string
		age    time.Duration
		change func(*idleEvidenceRegistry, *production.Provider)
		want   float64
	}{
		{"stale_idle", staleIdleDecode, func(*idleEvidenceRegistry, *production.Provider) {}, freshnessMedian},
		{"fresh", time.Second, func(*idleEvidenceRegistry, *production.Provider) {}, 1},
		{"unknown_age", staleIdleDecode, func(r *idleEvidenceRegistry, p *production.Provider) {
			r.histories[p.ID].Reset()
		}, 1},
		{"busy", staleIdleDecode, func(_ *idleEvidenceRegistry, p *production.Provider) {
			p.Mu().Lock()
			used := 0.5
			p.BackendCapacity.WholeMacServiceUsed = &used
			p.Mu().Unlock()
		}, 1},
		{"pending", staleIdleDecode, func(_ *idleEvidenceRegistry, p *production.Provider) {
			p.AddPending(freshnessRequest("prior"))
		}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := freshnessRegistry(slices.Repeat([]float64{freshnessMedian}, 10)...)
			p := freshnessProvider(t, r, "idle", 1, tc.age)
			tc.change(r, p)
			if got := soleFreshnessDecode(t, r, p, "request"); got != tc.want {
				t.Fatalf("decode TPS=%v, want %v", got, tc.want)
			}
		})
	}
	t.Run("no_median", func(t *testing.T) {
		r := freshnessRegistry()
		p := freshnessProvider(t, r, "idle", 1, staleIdleDecode)
		if got := soleFreshnessDecode(t, r, p, "request"); got != freshnessStatic {
			t.Fatalf("decode TPS=%v, want the registration rate %v", got, freshnessStatic)
		}
	})
}

func TestIdleDecodeRankingCanRecoverWithoutQualifyingDeadline(t *testing.T) {
	r := freshnessRegistry(freshnessMedian)
	idle := freshnessProvider(t, r, "idle", 1, staleIdleDecode)
	busy := freshnessProvider(t, r, "busy", freshnessMedian, staleIdleDecode)
	prior := freshnessRequest("decoding")
	prior.MarkContentCommitted()
	busy.AddPending(prior)
	request := freshnessRequest("new")
	request.FirstContentDeadline = time.Now().Add(10 * time.Second)
	selected, decision := r.registry.ReserveProviderEx(freshnessModel, request)
	if selected != idle {
		t.Fatalf("selected %v, want idle provider recovered through fleet estimate: %+v", selected, decision)
	}
	if decision.FirstContent.Status != production.FirstContentUnknown {
		t.Fatalf("ranking fallback invented deadline evidence: %+v", decision.FirstContent)
	}
	if idle.GetPending(request.RequestID) != request ||
		admission.PendingTokenBudget(request.EstimatedPromptTokens, request.RequestedMaxTokens, memorypolicy.DefaultRequestedMaxTokens) != 628 {
		t.Fatal("recovery bypassed physical reservation")
	}
	idle.RemovePending(request.RequestID)
	busy.RemovePending(prior.RequestID)
}

func TestIdleDecodeAgeIsIndependentOfPrefillAndHeartbeat(t *testing.T) {
	r := freshnessRegistry(slices.Repeat([]float64{freshnessMedian}, 10)...)
	p := freshnessProvider(t, r, "idle", 1, staleIdleDecode)
	capacity := p.BackendCapacitySnapshot()
	capacity.CapacitySeq = 1
	capacity.Slots[0].PerformanceMeasurements.IsolatedPrefill.SampleCount++
	if !r.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
		t.Fatal("heartbeat rejected")
	}
	if got := soleFreshnessDecode(t, r, p, "unchanged"); got != freshnessMedian {
		t.Fatalf("heartbeat or fresh prefill renewed decode age: decode TPS=%v, want %v", got, freshnessMedian)
	}
	capacity = p.BackendCapacitySnapshot()
	capacity.CapacitySeq = 2
	capacity.Slots[0].ObservedDecodeTPS = 90
	decode := capacity.Slots[0].PerformanceMeasurements.Decode
	decode.TokensPerSecond, decode.SampleCount, decode.SampleAgeMS = 90, decode.SampleCount+1, 0
	if !r.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
		t.Fatal("changed heartbeat rejected")
	}
	if got := soleFreshnessDecode(t, r, p, "renewed"); got != 90 {
		t.Fatalf("fresh decode rate=%v, want 90", got)
	}
}

func TestIdleDecodeAgingUsesExplicitObservationCounts(t *testing.T) {
	// Keep the peer median distinct as these heartbeats add slow samples.
	r := freshnessRegistry(slices.Repeat([]float64{freshnessMedian}, 10)...)
	p := freshnessProvider(t, r, "idle", 1, staleIdleDecode)
	capacity := p.BackendCapacitySnapshot()
	for step := uint64(1); step <= 4; step++ {
		capacity.CapacitySeq = step
		if !r.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
			t.Fatal("explicit measurement heartbeat rejected")
		}
		want := freshnessMedian
		if step == 4 {
			want = 1 // A new sample count refreshes even an unchanged rate.
		}
		if got := soleFreshnessDecode(t, r, p, "step"); got != want {
			t.Fatalf("step %d: decode TPS=%v, want %v", step, got, want)
		}
		capacity = p.BackendCapacitySnapshot()
		reported := capacity.Slots[0].PerformanceMeasurements
		switch step {
		case 1:
			reported.Decode.SampleAgeMS = 0 // A replay must not renew the sample.
		case 2:
			reported.IsolatedPrefill.SampleCount++ // Prefill is independent.
		case 3:
			reported.Decode.SampleCount++
		}
	}
}
