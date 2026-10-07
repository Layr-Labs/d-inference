package registry_test

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	pricingModel         = "exploration-pricing-model"
	pricingDecodeMedian  = 52.0
	pricingPrefillMedian = 2000.0
	// pricingStaticPrefill is the registration prefill fallback of a provider
	// that sent no rates: sqrt(400 GB/s) x 12.
	pricingStaticPrefill = 240.0
	pricingPrompt        = 1000
	pricingMaxTokens     = 256
)

// The rates have own values below both fleet medians, so each result shows
// which source was used.
func explorationRates(exploredDecode, exploredPrefill float64) performance.Rates {
	return performance.Rates{StaticDecode: 20, ObservedDecode: 5, FleetMedian: pricingDecodeMedian,
		StaticPrefill: pricingStaticPrefill, ObservedPrefill: 400,
		ExploredDecode: exploredDecode, ExploredPrefill: exploredPrefill}
}

func TestExploredRatesReplaceOwnRates(t *testing.T) {
	rates := explorationRates(pricingDecodeMedian, pricingPrefillMedian)
	if got := rates.Prefill(); got != pricingPrefillMedian {
		t.Fatalf("prefill %v, want the fleet median %v", got, pricingPrefillMedian)
	}
	if got := rates.EffectiveDecode(0); got != pricingDecodeMedian {
		t.Fatalf("decode %v, want the fleet median %v", got, pricingDecodeMedian)
	}
	// Each rate is replaced on its own.
	rates = explorationRates(0, pricingPrefillMedian)
	if got := rates.EffectiveDecode(0); got != 5 {
		t.Fatalf("decode %v, want the own EWMA 5", got)
	}
	rates = explorationRates(pricingDecodeMedian, 0)
	if got := rates.Prefill(); got != 400 {
		t.Fatalf("prefill %v, want the own EWMA 400", got)
	}
	// The explored prefill rate keeps the ordinary ceiling.
	rates = explorationRates(0, capacityvalue.MaxPrefillTPS+1)
	if got := rates.Prefill(); got != capacityvalue.MaxPrefillTPS {
		t.Fatalf("prefill %v, want the ceiling %v", got, capacityvalue.MaxPrefillTPS)
	}
}

func TestUnexploredRatesKeepOrdinaryFallbacks(t *testing.T) {
	rates := explorationRates(0, 0)
	if got := rates.Prefill(); got != 400 {
		t.Fatalf("prefill %v, want the observed EWMA 400", got)
	}
	if got := rates.EffectiveDecode(0); got != 5 {
		t.Fatalf("decode %v, want the observed EWMA 5", got)
	}
	rates.ObservedDecode, rates.ObservedPrefill = 0, 0
	if got := rates.Prefill(); got != pricingStaticPrefill {
		t.Fatalf("prefill %v, want the registration fallback %v, not the prefill median", got, pricingStaticPrefill)
	}
	rates.FleetMedian = 0
	if got := rates.EffectiveDecode(0); got != 20 {
		t.Fatalf("decode %v, want the registration fallback 20", got)
	}
}

func TestExploredRatesKeepReviewedProfilePointFirst(t *testing.T) {
	rates := explorationRates(pricingDecodeMedian, pricingPrefillMedian)
	rates.Profile = &performance.Profile{MaxConcurrency: 4,
		BatchCurve: []performance.BatchPoint{{Width: 1, DecodeP10TPS: 35, PrefillTPS: 900}}}
	if got := rates.Prefill(); got != 900 {
		t.Fatalf("prefill %v, want the profile point 900", got)
	}
	if got := rates.EffectiveDecode(0); got != 35 {
		t.Fatalf("decode %v, want the profile point 35", got)
	}
}

// The decode-floor projection keeps the provider's own rate chain.
func TestExploredDecodeDoesNotEnterProjectedDecode(t *testing.T) {
	rates := explorationRates(pricingDecodeMedian, 0)
	if got := rates.ProjectedDecode(0, 0, true); got != 5 {
		t.Fatalf("projected decode %v, want the own EWMA 5", got)
	}
}

func TestExplorationReplacesRate(t *testing.T) {
	bound := int32(forecast.EvidenceExplorationAfter / time.Millisecond)
	for _, tc := range []struct {
		name    string
		present bool
		ageMs   int32
		want    bool
	}{
		{"missing", false, -1, true},
		{"missing_with_age", false, 0, true},
		{"undated_own_rate", true, -1, false},
		{"fresh", true, 1000, false},
		{"just_inside_bound", true, bound - 1, false},
		{"at_bound", true, bound, true},
		{"old", true, bound + 60_000, true},
	} {
		if got := forecast.ExplorationReplacesRate(tc.present, tc.ageMs); got != tc.want {
			t.Errorf("%s: replaces=%v, want %v", tc.name, got, tc.want)
		}
	}
}

// IdleEvidenceGap is the provider-state half of EvidenceExplorable: the two
// agree whenever the forecast gap is performance evidence.
func TestIdleEvidenceGapMatchesExplorable(t *testing.T) {
	bound := int32(forecast.EvidenceExplorationAfter / time.Millisecond)
	performanceGap := forecast.Estimate{Status: forecast.Unknown, Reason: "performance_missing"}
	capacityGap := forecast.Estimate{Status: forecast.Unknown, Reason: "capacity_stale"}
	for _, loaded := range []bool{false, true} {
		for _, work := range []forecast.Workload{{}, {WholeMacKnown: true}, {WholeMacKnown: true, WholeMacBusy: true},
			{WholeMacKnown: true, PartialPrefillRows: 1}} {
			for _, pending := range []int{0, 1} {
				for _, gap := range []int32{-1, bound - 1, bound} {
					idle := forecast.IdleEvidenceGap(loaded, work, pending, gap)
					if got := forecast.EvidenceExplorable(performanceGap, loaded, work, pending, gap); got != idle {
						t.Errorf("loaded=%v work=%+v pending=%d gap=%d: explorable=%v, idle evidence gap=%v",
							loaded, work, pending, gap, got, idle)
					}
					if forecast.EvidenceExplorable(capacityGap, loaded, work, pending, gap) {
						t.Errorf("loaded=%v work=%+v pending=%d gap=%d: a capacity reason was explorable", loaded, work, pending, gap)
					}
				}
			}
		}
	}
	if !forecast.IdleEvidenceGap(true, forecast.Workload{WholeMacKnown: true}, 0, bound) {
		t.Fatal("an idle loaded provider at the bound must have an idle evidence gap")
	}
}

// pricingFixture is a registry whose fleet medians for pricingModel on the M3
// family are decode 52 tok/s and isolated prefill 2000 tok/s. The provider
// "fresh" connected connectionAge ago; every other provider connects now.
type pricingFixture struct {
	registry  *production.Registry
	histories map[string]*measurements.History
	now       time.Time
}

func newPricingFixture(t *testing.T, connectionAge time.Duration, prefillMedian bool) *pricingFixture {
	t.Helper()
	f := &pricingFixture{now: time.Now(), histories: map[string]*measurements.History{}}
	chip := testRegisterMessage().Hardware.ChipFamily
	throughput := production.NewTPSRegistry()
	for range 10 {
		throughput.Record(pricingModel, chip, pricingDecodeMedian)
		if prefillMedian {
			throughput.RecordPrefill(pricingModel, chip, pricingPrefillMedian)
		}
	}
	f.registry = production.NewWithDependencies(testLogger(), production.Dependencies{
		Throughput: throughput,
		Measurements: func(id string) *measurements.History {
			history := &measurements.History{}
			f.histories[id] = history
			return history
		},
		ConnectionOrigin: func(id string, at time.Time) *connectiontime.Origin {
			if id == "fresh" {
				return connectiontime.New(f.now.Add(-connectionAge))
			}
			return connectiontime.New(at)
		},
	})
	return f
}

// peer is idle and has fresh evidence: isolated prefill 2000 tok/s and decode
// 52 tok/s, the same as the fleet medians.
func (f *pricingFixture) peer(t *testing.T) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, f.registry, "peer", pricingModel, pricingDecodeMedian)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.CapacityAcceptedAt = f.now
	zero, initialized, prefill := int64(0), true, pricingPrefillMedian
	slot := &p.BackendCapacity.Slots[0]
	slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = pricingDecodeMedian, prefill
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
		IsolatedPrefillTPS: &prefill, EWMAInitialized: &initialized}
	slot.PerformanceMeasurements = localRateMeasurements(prefill, pricingDecodeMedian)
	f.histories["peer"].Reconcile(p.BackendCapacity, f.now, f.now, 0)
	return p
}

// fresh registers like a Swift provider: no decode or prefill rate at
// registration and no measurement yet.
func (f *pricingFixture) fresh(t *testing.T) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, f.registry, "fresh", pricingModel, 0)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.PrefillTPS != 0 || p.DecodeTPS != 0 {
		t.Fatalf("fresh provider has registration rates %v/%v, want none", p.PrefillTPS, p.DecodeTPS)
	}
	p.CapacityAcceptedAt = f.now
	zero, initialized := int64(0), false
	p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero,
		PartialPrefillRows: &zero, EWMAInitialized: &initialized}
	return p
}

func pricingRequest(id string) *production.PendingRequest {
	return &production.PendingRequest{RequestID: id, Model: pricingModel, EstimatedPromptTokens: pricingPrompt,
		RequestedMaxTokens: pricingMaxTokens, FirstContentDeadline: time.Now().Add(10 * time.Second)}
}

// pricedRates recovers the prefill and decode rates that priced the winner
// from its routing decision: ThisReqMs is prompt/prefill + output/decode.
func pricedRates(t *testing.T, decision production.RoutingDecision) (prefill, decode float64) {
	t.Helper()
	decode = decision.EffectiveTPS
	if decode <= 0 {
		t.Fatalf("decision has no decode rate: %+v", decision)
	}
	prefillMs := decision.ThisReqMs - float64(pricingMaxTokens)/decode*1000
	if prefillMs <= 0 {
		t.Fatalf("decision has no prefill cost: %+v", decision)
	}
	return float64(pricingPrompt) / prefillMs * 1000, decode
}

func assertRate(t *testing.T, name string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-6*want {
		t.Fatalf("%s %v, want %v", name, got, want)
	}
}

// A provider that sent no rates at registration used to be priced at the
// registration prefill fallback once exploration admitted it. With a
// 1000-token prompt that is about 4.3 s against about 0.7 s for an idle peer,
// far outside the 100 ms band, so it was never selected (#1238). The TTFT
// calibrator must not learn from a prediction built on a median.
func TestExploredFreshProviderIsSelectedWithinBand(t *testing.T) {
	cases := []struct {
		name          string
		connected     time.Duration
		prefillMedian bool
		wantSelected  bool
	}{
		{"explorable_with_medians", forecast.EvidenceExplorationAfter + time.Minute, true, true},
		{"explorable_without_prefill_median", forecast.EvidenceExplorationAfter + time.Minute, false, false},
		{"within_exploration_bound", forecast.EvidenceExplorationAfter - 2*time.Minute, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newPricingFixture(t, tc.connected, tc.prefillMedian)
			f.peer(t)
			fresh := f.fresh(t)
			wins := 0
			for i := range 64 {
				pr := pricingRequest(fmt.Sprintf("%s-r%d", t.Name(), i))
				p, decision := f.registry.ReserveProviderEx(pricingModel, pr)
				if p == nil {
					t.Fatal("no provider selected")
				}
				// A ratio of exactly 1 consumes the noted prediction without
				// moving the learned calibration.
				_, noted := production.RecordTTFTObservation(pr.RequestID, pr.Attempt, decision.RawTTFTMs)
				if p == fresh {
					wins++
					if noted && tc.prefillMedian {
						t.Fatal("the calibrator noted a prediction built on the fleet median")
					}
				} else if !noted {
					t.Fatal("the calibrator did not note the peer's prediction")
				}
				p.RemovePending(pr.RequestID)
			}
			if got := wins > 0; got != tc.wantSelected {
				t.Fatalf("fresh provider won %d of 64 reservations; want selected=%v", wins, tc.wantSelected)
			}
		})
	}
}

// slowMeasurement gives the provider slow own rates: isolated prefill 400 and
// decode 5 tok/s.
func slowMeasurement(p *production.Provider) {
	slot := &p.BackendCapacity.Slots[0]
	rate, initialized := 400.0, true
	slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = 5, rate
	slot.Telemetry.IsolatedPrefillTPS, slot.Telemetry.EWMAInitialized = &rate, &initialized
	slot.PerformanceMeasurements = localRateMeasurements(rate, 5)
}

// Each rate is replaced on its own. After one served request, the provider's
// own rate comes back for each rate the request renewed, even though the
// evidence gap has not closed.
func TestExploredProviderPricesEachRateOnItsOwn(t *testing.T) {
	old := forecast.EvidenceExplorationAfter + time.Minute
	cases := []struct {
		name        string
		serve       func(p *production.Provider, history *measurements.History, now time.Time)
		wantPrefill float64
		wantDecode  float64
	}{
		{
			name:        "never_measured",
			serve:       func(*production.Provider, *measurements.History, time.Time) {},
			wantPrefill: pricingPrefillMedian, wantDecode: pricingDecodeMedian,
		},
		{
			// The last measurements were slow and are now old.
			name: "measured_slow_then_idle",
			serve: func(p *production.Provider, history *measurements.History, now time.Time) {
				slowMeasurement(p)
				history.Reconcile(p.BackendCapacity, now.Add(-old), now.Add(-old), 0)
			},
			wantPrefill: pricingPrefillMedian, wantDecode: pricingDecodeMedian,
		},
		{
			// A later request renewed decode only: decode is its own, prefill
			// stays at the median.
			name: "decode_renewed_prefill_old",
			serve: func(p *production.Provider, history *measurements.History, now time.Time) {
				slowMeasurement(p)
				history.Reconcile(p.BackendCapacity, now.Add(-old), now.Add(-old), 0)
				slot := &p.BackendCapacity.Slots[0]
				slot.ObservedDecodeTPS = 30
				slot.PerformanceMeasurements = localRateMeasurements(400, 30)
				slot.PerformanceMeasurements.Decode.SampleCount = 2
				history.Reconcile(p.BackendCapacity, now.Add(-old), now, 0)
			},
			wantPrefill: pricingPrefillMedian, wantDecode: 30,
		},
		{
			// Explicit path, cache-hit request: decode is renewed, but no
			// isolated prefill sample exists. Decode is its own; prefill stays
			// at the median because its own evidence is missing.
			name: "explicit_cache_hit",
			serve: func(p *production.Provider, history *measurements.History, now time.Time) {
				slot := &p.BackendCapacity.Slots[0]
				slot.ObservedDecodeTPS = 30
				slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{Epoch: "e",
					Decode: &protocol.PerformanceRateObservation{TokensPerSecond: 30, SampleCount: 1}}
				history.Reconcile(p.BackendCapacity, time.Time{}, now, 0)
			},
			wantPrefill: pricingPrefillMedian, wantDecode: 30,
		},
		{
			// Legacy path: the first EWMA after connect is undated by design.
			// Both rates are the provider's own.
			name: "legacy_first_undated_ewma",
			serve: func(p *production.Provider, history *measurements.History, now time.Time) {
				slot := &p.BackendCapacity.Slots[0]
				rate, initialized := 700.0, true
				slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = 30, rate
				slot.Telemetry.IsolatedPrefillTPS, slot.Telemetry.EWMAInitialized = &rate, &initialized
				history.Reconcile(p.BackendCapacity, time.Time{}, now, 0)
			},
			wantPrefill: 700, wantDecode: 30,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newPricingFixture(t, old, true)
			p := f.fresh(t)
			p.Mu().Lock()
			tc.serve(p, f.histories["fresh"], f.now)
			p.Mu().Unlock()
			selected, decision := f.registry.ReserveProviderEx(pricingModel, pricingRequest("served"))
			if selected != p {
				t.Fatalf("selected=%v, want the only provider", selected)
			}
			prefill, decode := pricedRates(t, decision)
			assertRate(t, "prefill", prefill, tc.wantPrefill)
			assertRate(t, "decode", decode, tc.wantDecode)
		})
	}
}

// Pricing at the medians needs fresh accepted capacity and the idle evidence
// gap that exploration requires. Otherwise the provider keeps its own rates.
func TestExplorationPricingFollowsAdmission(t *testing.T) {
	explorable := forecast.EvidenceExplorationAfter + time.Minute
	cases := []struct {
		name      string
		connected time.Duration
		prepare   func(p *production.Provider, now time.Time)
		want      float64
	}{
		{"explorable", explorable, nil, pricingPrefillMedian},
		{"capacity_stale", explorable, func(p *production.Provider, now time.Time) {
			p.Mu().Lock()
			p.CapacityAcceptedAt = now.Add(-forecast.CapacityFreshness - time.Second)
			p.Mu().Unlock()
		}, pricingStaticPrefill},
		{"pending_request", explorable, func(p *production.Provider, _ time.Time) {
			held := pricingRequest("held")
			held.EstimatedPromptTokens, held.RequestedMaxTokens = 100, 16
			p.AddPending(held)
		}, pricingStaticPrefill},
		{"within_exploration_bound", time.Minute, nil, pricingStaticPrefill},
		{"model_not_loaded", explorable, func(p *production.Provider, _ time.Time) {
			p.Mu().Lock()
			p.BackendCapacity.Slots[0].State = "idle_shutdown"
			p.Mu().Unlock()
		}, pricingStaticPrefill},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newPricingFixture(t, tc.connected, true)
			p := f.fresh(t)
			if tc.prepare != nil {
				tc.prepare(p, f.now)
			}
			selected, decision := f.registry.ReserveProviderEx(pricingModel, pricingRequest("probe"))
			if selected != p {
				t.Fatalf("selected=%v, want the only provider (%+v)", selected, decision)
			}
			prefill, _ := pricedRates(t, decision)
			assertRate(t, "prefill", prefill, tc.want)
		})
	}
}
