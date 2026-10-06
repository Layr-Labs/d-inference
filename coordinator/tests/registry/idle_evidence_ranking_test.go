package registry_test

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// staleIdleDecodeAge is the age after which an idle provider's decode
// measurement must no longer lower its ranking. It mirrors
// idleDecodeMeasurementMaxAge from #1243. #1243 is not merged, so this test
// cannot reference that symbol yet. After #1243 merges, this test must use
// its constant instead of this copy. The value is a policy number and the
// maintainers own it.
const staleIdleDecodeAge = 30 * time.Minute

// idleEvidenceModel is the model of every provider in these tests.
const idleEvidenceModel = "idle-evidence-model"

// idleEvidenceFleet holds the random inputs for one comparison.
type idleEvidenceFleet struct {
	fleetSamples []float64
	staticDecode float64
	prefill      float64 // 0: the provider reports no prefill measurement
	decode       float64
	// measurementAge dates both the prefill and the decode measurement.
	measurementAge time.Duration
	prompt         int
}

func randomIdleEvidenceFleet(rng *rand.Rand) idleEvidenceFleet {
	f := idleEvidenceFleet{
		staticDecode:   float64(rng.Intn(3)) * (10 + 90*rng.Float64()), // 0 means not registered
		decode:         1 + 199*rng.Float64(),
		measurementAge: staleIdleDecodeAge + time.Duration(rng.Int63n(int64(12*time.Hour))) + time.Millisecond,
		prompt:         1 + rng.Intn(8000),
	}
	if rng.Intn(2) == 0 {
		f.prefill = 100 + 4900*rng.Float64()
	}
	for range rng.Intn(20) {
		f.fleetSamples = append(f.fleetSamples, 5+195*rng.Float64())
	}
	return f
}

// idleEvidenceRegistry is a registry whose fleet median decode rate comes
// only from the given samples. It keeps each provider's measurement history,
// so a test can report dated measurements for the provider.
type idleEvidenceRegistry struct {
	registry  *production.Registry
	histories map[string]*measurements.History
}

func newIdleEvidenceRegistry(fleetSamples []float64) *idleEvidenceRegistry {
	throughput := production.NewTPSRegistry()
	for _, tps := range fleetSamples {
		throughput.Record(idleEvidenceModel, testRegisterMessage().Hardware.ChipFamily, tps)
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

// addProvider registers an idle provider with the model loaded and complete
// work telemetry. Its prefill measurement, when f has one, and its decode
// measurement, when withDecode is set, are measurementAge old.
func (r *idleEvidenceRegistry) addProvider(t *testing.T, id string, f idleEvidenceFleet, withDecode bool, now time.Time) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r.registry, id, idleEvidenceModel, f.staticDecode)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.CapacityAcceptedAt = now
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	initialized := f.prefill > 0
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64), EWMAInitialized: &initialized}
	reported := &protocol.PerformanceMeasurements{Epoch: "idle-evidence"}
	ageMS := f.measurementAge.Milliseconds()
	if f.prefill > 0 {
		prefill := f.prefill
		slot.ObservedPrefillTPS = prefill
		slot.Telemetry.IsolatedPrefillTPS = &prefill
		reported.IsolatedPrefill = &protocol.PerformanceRateObservation{TokensPerSecond: prefill, SampleCount: 1, SampleAgeMS: ageMS}
	}
	if withDecode {
		slot.ObservedDecodeTPS = f.decode
		reported.Decode = &protocol.PerformanceRateObservation{TokensPerSecond: f.decode, SampleCount: 1, SampleAgeMS: ageMS}
	}
	slot.PerformanceMeasurements = reported
	r.histories[id].Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
	return p
}

func idleEvidenceRequest(id string, prompt int) *production.PendingRequest {
	return &production.PendingRequest{RequestID: id, Model: idleEvidenceModel, EstimatedPromptTokens: prompt,
		RequestedMaxTokens: 256, FirstContentDeadline: time.Now().Add(10 * time.Second)}
}

// soleProviderDecision routes one request in a fleet that holds only one
// idle provider built from f. The decision carries that provider's effective
// decode rate and first-content forecast.
func soleProviderDecision(t *testing.T, f idleEvidenceFleet, withDecode bool, now time.Time) production.RoutingDecision {
	t.Helper()
	r := newIdleEvidenceRegistry(f.fleetSamples)
	r.addProvider(t, "idle", f, withDecode, now)
	p, decision := r.registry.ReserveProviderEx(idleEvidenceModel, idleEvidenceRequest("request", f.prompt))
	if p == nil {
		t.Fatalf("%+v: the only idle provider was not selected: %+v", f, decision)
	}
	return decision
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
			measured := soleProviderDecision(t, f, true, now)
			unmeasured := soleProviderDecision(t, f, false, now)
			if measured.EffectiveTPS < unmeasured.EffectiveTPS || measured.FirstContent.ExpectedMs > unmeasured.FirstContent.ExpectedMs {
				t.Fatalf("seed %d case %d: %+v\nmeasured decode aged %s ranks below no measurement: "+
					"effective %.2f < %.2f tok/s or expected %.1f > %.1f ms",
					seed, i, f, f.measurementAge, measured.EffectiveTPS, unmeasured.EffectiveTPS,
					measured.FirstContent.ExpectedMs, unmeasured.FirstContent.ExpectedMs)
			}
		}
	}
}

// TestIdleDecodeMeasurementAgeDoesNotLoseSelection states the same property
// with both providers in one fleet. Two identical idle providers differ only
// in that one reports a decode measurement older than staleIdleDecodeAge. The
// old value is far below the fleet median. Neither has usable first-content
// evidence, so they tie unless the old value lowers the measured provider's
// rank. Across 64 reservations the measured provider must win at least once.
func TestIdleDecodeMeasurementAgeDoesNotLoseSelection(t *testing.T) {
	now := time.Now()
	r := newIdleEvidenceRegistry(slices.Repeat([]float64{52}, 10))
	f := idleEvidenceFleet{decode: 5, measurementAge: staleIdleDecodeAge + time.Minute, prompt: 1000}
	measured := r.addProvider(t, "measured", f, true, now)
	r.addProvider(t, "unmeasured", f, false, now)
	wins := 0
	for i := range 64 {
		pr := idleEvidenceRequest(fmt.Sprintf("r%d", i), f.prompt)
		p, _ := r.registry.ReserveProviderEx(idleEvidenceModel, pr)
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
			f.measurementAge, f.decode)
	}
}

// TestExploredIdleProviderIsCostedAtFleetMedian asserts a proposed policy.
// It is not a regression test for #1243 or #1254. #1254 admits an idle
// provider without usable evidence to the pool after
// forecast.EvidenceExplorationAfter, and it does not promise that the
// provider is selected. #1243, which is not merged, keeps an old decode rate
// until staleIdleDecodeAge, on purpose. The proposed policy goes beyond both:
// from forecast.EvidenceExplorationAfter, an explored provider is costed at
// the fleet median, so that admission can lead to selection. This test checks
// the decode half of that policy. The closed-loop tests in
// tests/registry/routingsim cover the prefill half. The maintainers own this
// policy.
func TestExploredIdleProviderIsCostedAtFleetMedian(t *testing.T) {
	const fleetMedian = 52.0
	for _, tc := range []struct {
		name       string
		withDecode bool
		age        time.Duration
	}{
		{"no_measurement", false, 0},
		{"measured_just_past_exploration_bound", true, forecast.EvidenceExplorationAfter + time.Minute},
		{"measured_past_stale_decode_age", true, staleIdleDecodeAge + time.Minute},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := idleEvidenceFleet{fleetSamples: slices.Repeat([]float64{fleetMedian}, 10),
				decode: 5, measurementAge: tc.age, prefill: 2000, prompt: 1000}
			decision := soleProviderDecision(t, f, tc.withDecode, time.Now())
			if decision.FirstContent.Status == production.FirstContentFeasible {
				t.Fatalf("idle provider with %s-old evidence is feasible: %+v", tc.age, decision.FirstContent)
			}
			if decision.EffectiveTPS != fleetMedian {
				t.Fatalf("explored provider costed at %.1f tok/s, want the fleet median %.1f (measurement age %s)",
					decision.EffectiveTPS, fleetMedian, tc.age)
			}
		})
	}
}
