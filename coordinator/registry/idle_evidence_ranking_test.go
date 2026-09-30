package registry

import (
	"fmt"
	"math/rand"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// staleIdleDecodeAge is the age after which an idle provider's decode
// measurement must no longer lower its ranking. Thirty minutes is the bound
// proposed in #1243. It is a policy number and the maintainers own it.
const staleIdleDecodeAge = 30 * time.Minute

// idleEvidenceModel is the model of every provider in these tests.
const idleEvidenceModel = "idle-evidence-model"

// idleEvidenceFleet holds the random inputs for one comparison.
type idleEvidenceFleet struct {
	fleetSamples []float64
	staticDecode float64
	prefill      float64 // 0: the provider reports no prefill measurement
	decode       float64
	decodeAge    time.Duration
	prompt       int
}

func randomIdleEvidenceFleet(rng *rand.Rand) idleEvidenceFleet {
	f := idleEvidenceFleet{
		staticDecode: float64(rng.Intn(3)) * (10 + 90*rng.Float64()), // 0 means not registered
		decode:       1 + 199*rng.Float64(),
		decodeAge:    staleIdleDecodeAge + time.Duration(rng.Int63n(int64(12*time.Hour))) + time.Millisecond,
		prompt:       1 + rng.Intn(8000),
	}
	if rng.Intn(2) == 0 {
		f.prefill = 100 + 4900*rng.Float64()
	}
	for range rng.Intn(20) {
		f.fleetSamples = append(f.fleetSamples, 5+195*rng.Float64())
	}
	return f
}

// idleEvidenceProvider registers an idle provider with the model loaded and
// complete work telemetry. withDecode adds a dated decode measurement.
func idleEvidenceProvider(t *testing.T, r *Registry, id string, f idleEvidenceFleet, withDecode bool, now time.Time) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, idleEvidenceModel, f.staticDecode)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.CapacityAcceptedAt = now
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	initialized := f.prefill > 0
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64), EWMAInitialized: &initialized}
	measurement := firstContentMeasurement{}
	if f.prefill > 0 {
		prefill := f.prefill
		slot.ObservedPrefillTPS = prefill
		slot.Telemetry.IsolatedPrefillTPS = &prefill
		measurement.rate, measurement.observedAfter = prefill, now.Add(-f.decodeAge)
	}
	if withDecode {
		slot.ObservedDecodeTPS = f.decode
		measurement.decodeRate, measurement.decodeObservedAfter = f.decode, now.Add(-f.decodeAge)
	}
	p.firstContentMeasurements = map[string]firstContentMeasurement{idleEvidenceModel: measurement}
	return p
}

func idleEvidenceCandidate(r *Registry, p *Provider, pr *PendingRequest, now time.Time) *routingCandidate {
	c := &routingCandidate{}
	p.mu.Lock()
	r.fillRoutingSnapshotPLocked(&c.snapshot, p, idleEvidenceModel, now)
	p.mu.Unlock()
	r.estimateFirstContent(c, pr, now)
	return c
}

// TestIdleDecodeMeasurementAgeNeverRanksBelowNoMeasurement checks measurement
// monotonicity. An idle, loaded provider that reports a decode measurement
// older than staleIdleDecodeAge must not rank lower than the same provider
// with no decode measurement. Otherwise the provider is ranked lower only
// because of an old value, and only new work, which the lower rank prevents,
// can replace that value (#1238).
func TestIdleDecodeMeasurementAgeNeverRanksBelowNoMeasurement(t *testing.T) {
	for _, seed := range []int64{1238, 1243, 1254, 20260929} {
		rng := rand.New(rand.NewSource(seed))
		for i := range 250 {
			f := randomIdleEvidenceFleet(rng)
			now := time.Now()
			r := New(testLogger())
			for _, tps := range f.fleetSamples {
				r.tpsRegistry.Record(idleEvidenceModel, testRegisterMessage().Hardware.ChipFamily, tps)
			}
			pr := &PendingRequest{Model: idleEvidenceModel, EstimatedPromptTokens: f.prompt, RequestedMaxTokens: 256,
				FirstContentDeadline: now.Add(10 * time.Second)}
			measured := idleEvidenceCandidate(r, idleEvidenceProvider(t, r, "measured", f, true, now), pr, now)
			unmeasured := idleEvidenceCandidate(r, idleEvidenceProvider(t, r, "unmeasured", f, false, now), pr, now)
			withTPS, withoutTPS := resolveEffectiveTPS(&measured.snapshot), resolveEffectiveTPS(&unmeasured.snapshot)
			if withTPS < withoutTPS || measured.firstContent.ExpectedMs > unmeasured.firstContent.ExpectedMs {
				t.Fatalf("seed %d case %d: %+v\nmeasured decode aged %s ranks below no measurement: "+
					"effective %.2f < %.2f tok/s or expected %.1f > %.1f ms",
					seed, i, f, f.decodeAge, withTPS, withoutTPS,
					measured.firstContent.ExpectedMs, unmeasured.firstContent.ExpectedMs)
			}
		}
	}
}

// TestIdleDecodeMeasurementAgeDoesNotLoseSelection states the same property
// through ReserveProviderEx. Two identical idle providers differ only in that
// one reports a decode measurement older than staleIdleDecodeAge. The old
// value is far below the fleet median. Neither has usable first-content
// evidence, so they tie unless the old value lowers the measured provider's
// rank. Across 64 reservations the measured provider must win at least once.
func TestIdleDecodeMeasurementAgeDoesNotLoseSelection(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	for range 10 {
		r.tpsRegistry.Record(idleEvidenceModel, testRegisterMessage().Hardware.ChipFamily, 52)
	}
	f := idleEvidenceFleet{decode: 5, decodeAge: staleIdleDecodeAge + time.Minute, prompt: 1000}
	measured := idleEvidenceProvider(t, r, "measured", f, true, now)
	idleEvidenceProvider(t, r, "unmeasured", f, false, now)
	wins := 0
	for i := range 64 {
		pr := &PendingRequest{RequestID: fmt.Sprintf("r%d", i), Model: idleEvidenceModel, EstimatedPromptTokens: f.prompt,
			RequestedMaxTokens: 256, FirstContentDeadline: time.Now().Add(10 * time.Second)}
		p, _ := r.ReserveProviderEx(idleEvidenceModel, pr)
		if p == nil {
			t.Fatal("no provider selected")
		}
		if p == measured {
			wins++
		}
		p.RemovePending(pr.RequestID)
	}
	if wins == 0 {
		t.Fatalf("the provider with a %s-old decode measurement of %.0f tok/s never won against an identical provider with none",
			f.decodeAge, f.decode)
	}
}

// TestExploredIdleProviderIsCostedAtFleetMedian checks the combined result
// that #1243 and #1254 aim for. #1254 lets an idle provider without usable
// evidence compete after five minutes. The provider must then be costed at
// the fleet median decode rate, not at an old slow value. Otherwise it is
// admitted to the pool but still cannot win.
func TestExploredIdleProviderIsCostedAtFleetMedian(t *testing.T) {
	const fleetMedian = 52.0
	for _, tc := range []struct {
		name       string
		withDecode bool
		age        time.Duration
	}{
		{"no_measurement", false, 0},
		{"measured_just_past_exploration_bound", true, 5*time.Minute + time.Minute},
		{"measured_past_stale_decode_age", true, staleIdleDecodeAge + time.Minute},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r := New(testLogger())
			for range 10 {
				r.tpsRegistry.Record(idleEvidenceModel, testRegisterMessage().Hardware.ChipFamily, fleetMedian)
			}
			f := idleEvidenceFleet{decode: 5, decodeAge: tc.age, prefill: 2000, prompt: 1000}
			p := idleEvidenceProvider(t, r, "explored", f, tc.withDecode, now)
			pr := &PendingRequest{Model: idleEvidenceModel, EstimatedPromptTokens: f.prompt, RequestedMaxTokens: 256,
				FirstContentDeadline: now.Add(10 * time.Second)}
			c := idleEvidenceCandidate(r, p, pr, now)
			if c.firstContent.Status == FirstContentFeasible {
				t.Fatalf("idle provider with %s-old evidence is feasible: %+v", tc.age, c.firstContent)
			}
			if got := resolveEffectiveTPS(&c.snapshot); got != fleetMedian {
				t.Fatalf("explored provider costed at %.1f tok/s, want the fleet median %.1f (decode measurement age %s)",
					got, fleetMedian, tc.age)
			}
		})
	}
}
