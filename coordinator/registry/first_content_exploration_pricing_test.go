package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// pricingSnapshot has its own rates below both fleet medians, so each resolve
// result shows which source was used. Both own rates are dated and older than
// the exploration bound.
func pricingSnapshot(admitted bool) routingSnapshot {
	old := int32((firstContentEvidenceExplorationAfter + time.Minute) / time.Millisecond)
	s := routingSnapshot{
		explorationAdmitted:   admitted,
		decodeEvidenceAgeMs:   old,
		prefillEvidenceAgeMs:  old,
		fleetMedianTPS:        52,
		fleetMedianPrefillTPS: 2000,
		observedDecodeTPS:     5,
		observedPrefillTPS:    400,
		decodeTPS:             20,
		prefillTPS:            240,
	}
	s.isolatedPrefillInitialized, s.isolatedPrefillTPS = true, 400
	return s
}

func TestExplorationAdmittedSnapshotUsesFleetMedians(t *testing.T) {
	s := pricingSnapshot(true)
	if got := resolvePrefillTPS(&s); got != 2000 {
		t.Fatalf("prefill %v, want the fleet median 2000", got)
	}
	if got := resolveEffectiveTPS(&s); got != 52 {
		t.Fatalf("decode %v, want the fleet median 52", got)
	}
}

func TestExplorationAdmittedSnapshotWithoutMediansKeepsFallbacks(t *testing.T) {
	s := pricingSnapshot(true)
	s.fleetMedianTPS, s.fleetMedianPrefillTPS = 0, 0
	if got := resolvePrefillTPS(&s); got != 400 {
		t.Fatalf("prefill %v, want the observed EWMA 400", got)
	}
	if got := resolveEffectiveTPS(&s); got != 5 {
		t.Fatalf("decode %v, want the observed EWMA 5", got)
	}
	s.observedDecodeTPS, s.observedPrefillTPS = 0, 0
	if got := resolvePrefillTPS(&s); got != 240 {
		t.Fatalf("prefill %v, want the registration fallback 240", got)
	}
	if got := resolveEffectiveTPS(&s); got != 20 {
		t.Fatalf("decode %v, want the registration fallback 20", got)
	}
}

func TestSnapshotNotExplorationAdmittedKeepsOwnRates(t *testing.T) {
	s := pricingSnapshot(false)
	if got := resolvePrefillTPS(&s); got != 400 {
		t.Fatalf("prefill %v, want the observed EWMA 400", got)
	}
	if got := resolveEffectiveTPS(&s); got != 5 {
		t.Fatalf("decode %v, want the observed EWMA 5", got)
	}
	s.observedDecodeTPS, s.observedPrefillTPS = 0, 0
	if got := resolvePrefillTPS(&s); got != 240 {
		t.Fatalf("prefill %v, want the registration fallback 240, not the prefill median", got)
	}
}

// Each rate is replaced on its own. A fresh or undated own rate is kept even
// when the other rate still uses the fleet median.
func TestExplorationReplacesEachRateOnItsOwn(t *testing.T) {
	fresh := int32(time.Second / time.Millisecond)
	s := pricingSnapshot(true)
	s.decodeEvidenceAgeMs = fresh
	if got := resolveEffectiveTPS(&s); got != 5 {
		t.Fatalf("decode %v, want the fresh own EWMA 5", got)
	}
	if got := resolvePrefillTPS(&s); got != 2000 {
		t.Fatalf("prefill %v, want the fleet median 2000 for the old prefill", got)
	}
	s = pricingSnapshot(true)
	s.decodeEvidenceAgeMs, s.prefillEvidenceAgeMs = -1, -1
	if got := resolveEffectiveTPS(&s); got != 5 {
		t.Fatalf("decode %v, want the undated own EWMA 5", got)
	}
	if got := resolvePrefillTPS(&s); got != 400 {
		t.Fatalf("prefill %v, want the undated own EWMA 400", got)
	}
}

// After one served request, the provider's own rates must replace the median
// even though the evidence gap has not closed. The admitted flag stays set in
// both cases, because one of the two measurements is still undated.
func TestExploredProviderUsesOwnRatesAfterServedRequest(t *testing.T) {
	cases := []struct {
		name        string
		serve       func(p *Provider, now time.Time)
		wantDecode  float64
		wantPrefill float64
	}{
		{
			// Explicit path, cache-hit request: decode is renewed, but no
			// isolated prefill sample exists. Decode is its own; prefill
			// stays at the median because its own evidence is missing.
			name: "explicit_cache_hit",
			serve: func(p *Provider, now time.Time) {
				slot := &p.BackendCapacity.Slots[0]
				slot.ObservedDecodeTPS = 30
				p.firstContentMeasurements = map[string]firstContentMeasurement{pricingModel: {
					epoch: "e", decodeRate: 30, decodeCount: 1, decodeObservedAfter: now}}
			},
			wantDecode: 30, wantPrefill: 2000,
		},
		{
			// Legacy path: the first EWMA after connect is undated by design
			// (reconcileFirstContentMeasurementsLocked). Both rates are own.
			name: "legacy_first_undated_ewma",
			serve: func(p *Provider, now time.Time) {
				slot := &p.BackendCapacity.Slots[0]
				rate, initialized := 700.0, true
				slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = 30, rate
				slot.Telemetry.IsolatedPrefillTPS, slot.Telemetry.EWMAInitialized = &rate, &initialized
				p.firstContentMeasurements = map[string]firstContentMeasurement{pricingModel: {rate: rate, decodeRate: 30}}
			},
			wantDecode: 30, wantPrefill: 700,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r := New(testLogger())
			chip := testRegisterMessage().Hardware.ChipFamily
			for range 10 {
				r.tpsRegistry.Record(pricingModel, chip, 52)
				r.tpsRegistry.RecordPrefill(pricingModel, chip, 2000)
			}
			p := pricingFreshProvider(t, r, firstContentEvidenceExplorationAfter+time.Minute, now)
			c := &routingCandidate{}
			p.mu.Lock()
			tc.serve(p, now)
			r.fillRoutingSnapshotPLocked(&c.snapshot, p, pricingModel, now)
			p.mu.Unlock()
			if !c.snapshot.explorationAdmitted {
				t.Fatal("provider is not admitted; the case does not test pricing")
			}
			if got := resolveEffectiveTPS(&c.snapshot); got != tc.wantDecode {
				t.Fatalf("decode %v, want %v", got, tc.wantDecode)
			}
			if got := resolvePrefillTPS(&c.snapshot); got != tc.wantPrefill {
				t.Fatalf("prefill %v, want %v", got, tc.wantPrefill)
			}
		})
	}
}

func TestExplorationPricingKeepsReviewedProfilePointFirst(t *testing.T) {
	s := pricingSnapshot(true)
	s.performanceProfile = &servingPerformanceProfile{MaxConcurrency: 4,
		BatchCurve: []servingBatchPoint{{Width: 1, DecodeP10TPS: 35, PrefillTPS: 900}}}
	if got := resolvePrefillTPS(&s); got != 900 {
		t.Fatalf("prefill %v, want the profile point 900", got)
	}
	if got := resolveEffectiveTPS(&s); got != 35 {
		t.Fatalf("decode %v, want the profile point 35", got)
	}
}

const pricingModel = "exploration-pricing-model"

// pricingPeer is idle and has fresh evidence: isolated prefill 2000 tok/s and
// decode 52 tok/s, the same as the fleet medians.
func pricingPeer(t *testing.T, r *Registry, now time.Time) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, "peer", pricingModel, 52)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.CapacityAcceptedAt = now
	zero, initialized, prefill := int64(0), true, 2000.0
	slot := &p.BackendCapacity.Slots[0]
	slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = 52, prefill
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
		IsolatedPrefillTPS: &prefill, EWMAInitialized: &initialized}
	p.firstContentMeasurements = map[string]firstContentMeasurement{pricingModel: {
		rate: prefill, decodeRate: 52, observedAfter: now, decodeObservedAfter: now}}
	return p
}

// pricingFreshProvider registers like a Swift provider: no decode or prefill
// rate at registration and no measurement yet. Its registration prefill
// fallback is sqrt(400 GB/s) x 12 = 240 tok/s.
func pricingFreshProvider(t *testing.T, r *Registry, connected time.Duration, now time.Time) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, "fresh", pricingModel, 0)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.PrefillTPS != 0 || p.DecodeTPS != 0 {
		t.Fatalf("fresh provider has registration rates %v/%v, want none", p.PrefillTPS, p.DecodeTPS)
	}
	p.registeredAt = now.Add(-connected)
	p.CapacityAcceptedAt = now
	zero, initialized := int64(0), false
	p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero,
		PartialPrefillRows: &zero, EWMAInitialized: &initialized}
	return p
}

// A provider that sent no rates at registration used to be priced at the
// registration prefill fallback once exploration admitted it. With a
// 1000-token prompt that is about 4.3 s against about 0.7 s for an idle peer,
// far outside the 100 ms band, so it was never selected (#1238).
func TestExploredFreshProviderIsSelectedWithinBand(t *testing.T) {
	cases := []struct {
		name          string
		connected     time.Duration
		prefillMedian bool
		wantSelected  bool
	}{
		{"explorable_with_medians", firstContentEvidenceExplorationAfter + time.Minute, true, true},
		{"explorable_without_prefill_median", firstContentEvidenceExplorationAfter + time.Minute, false, false},
		{"within_exploration_bound", firstContentEvidenceExplorationAfter - 2*time.Minute, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r := New(testLogger())
			chip := testRegisterMessage().Hardware.ChipFamily
			for range 10 {
				r.tpsRegistry.Record(pricingModel, chip, 52)
				if tc.prefillMedian {
					r.tpsRegistry.RecordPrefill(pricingModel, chip, 2000)
				}
			}
			pricingPeer(t, r, now)
			fresh := pricingFreshProvider(t, r, tc.connected, now)
			wins := 0
			for i := range 64 {
				pr := &PendingRequest{RequestID: fmt.Sprintf("%s-r%d", t.Name(), i), Model: pricingModel, EstimatedPromptTokens: 1000,
					RequestedMaxTokens: 256, FirstContentDeadline: time.Now().Add(10 * time.Second)}
				p, _ := r.ReserveProviderEx(pricingModel, pr)
				if p == nil {
					t.Fatal("no provider selected")
				}
				ttftCalibration.mu.RLock()
				_, noted := ttftCalibration.pending[ttftPendingKey(pr.RequestID, pr.Attempt)]
				ttftCalibration.mu.RUnlock()
				ttftCalibration.discardPrediction(pr.RequestID, pr.Attempt)
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

// The snapshot flag must agree with firstContentEvidenceExplorable whenever
// the forecast gap is performance evidence, and must stay false when capacity
// or work state rules exploration out.
func TestExplorationAdmittedFlagMatchesExplorablePredicate(t *testing.T) {
	cases := []struct {
		name    string
		prepare func(p *Provider, now time.Time)
		want    bool
	}{
		{"explorable", func(*Provider, time.Time) {}, true},
		{"capacity_stale", func(p *Provider, now time.Time) {
			p.CapacityAcceptedAt = now.Add(-firstContentFreshness - time.Second)
		}, false},
		{"pending_request", func(p *Provider, _ time.Time) {
			held := planTestRequest("held", 100, 16)
			held.Model = pricingModel
			p.pendingReqs[held.RequestID] = held
		}, false},
		{"within_exploration_bound", func(p *Provider, now time.Time) { p.registeredAt = now.Add(-time.Minute) }, false},
		{"model_not_loaded", func(p *Provider, _ time.Time) { p.BackendCapacity.Slots[0].State = "idle_shutdown" }, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r := New(testLogger())
			p := pricingFreshProvider(t, r, firstContentEvidenceExplorationAfter+time.Minute, now)
			c := &routingCandidate{}
			p.mu.Lock()
			tc.prepare(p, now)
			r.fillRoutingSnapshotPLocked(&c.snapshot, p, pricingModel, now)
			p.mu.Unlock()
			if c.snapshot.explorationAdmitted != tc.want {
				t.Fatalf("explorationAdmitted=%v, want %v", c.snapshot.explorationAdmitted, tc.want)
			}
			pr := &PendingRequest{Model: pricingModel, EstimatedPromptTokens: 1000, RequestedMaxTokens: 256,
				FirstContentDeadline: now.Add(10 * time.Second)}
			r.estimateFirstContent(c, pr, now)
			if got := firstContentEvidenceExplorable(c); got != c.snapshot.explorationAdmitted {
				t.Fatalf("firstContentEvidenceExplorable=%v but explorationAdmitted=%v (forecast %+v)",
					got, c.snapshot.explorationAdmitted, c.firstContent)
			}
		})
	}
}
