package registry_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestExplicitPerformanceMeasurementFreshness(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	history := &measurements.History{}
	capacity := measurementCapacity()
	history.Reconcile(capacity, time.Time{}, now, time.Second)
	sample, _ := history.Lookup("m")
	if !sample.ObservedAfter.Equal(now.Add(-3*time.Second)) || !sample.DecodeObservedAfter.Equal(now.Add(-2*time.Second)) {
		t.Fatalf("fresh first report lost explicit observation: %+v", sample)
	}
	// Replayed metadata with a new capacity sequence cannot renew either rate.
	history.Reconcile(capacity, time.Time{}, now.Add(time.Minute), time.Second)
	if got, _ := history.Lookup("m"); !got.ObservedAfter.Equal(sample.ObservedAfter) || !got.DecodeObservedAfter.Equal(sample.DecodeObservedAfter) {
		t.Fatalf("same counts rejuvenated: %+v", got)
	}
	pm := capacity.Slots[0].PerformanceMeasurements
	pm.IsolatedPrefill.SampleCount++
	history.Reconcile(capacity, time.Time{}, now.Add(time.Minute), time.Second)
	got, _ := history.Lookup("m")
	if !got.ObservedAfter.Equal(now.Add(57*time.Second)) || !got.DecodeObservedAfter.Equal(sample.DecodeObservedAfter) {
		t.Fatalf("equal new prefill did not independently refresh: %+v", got)
	}
	// Reset counters are allowed only with a different engine lifetime.
	pm.IsolatedPrefill.SampleCount = 1
	history.Reconcile(capacity, time.Time{}, now.Add(2*time.Minute), time.Second)
	if sample, _ := history.Lookup("m"); !sample.ObservedAfter.IsZero() {
		t.Fatal("regressed count retained freshness")
	}
	pm.Epoch = "engine-b"
	history.Reconcile(capacity, time.Time{}, now.Add(2*time.Minute), time.Second)
	if sample, _ := history.Lookup("m"); sample.ObservedAfter.IsZero() {
		t.Fatal("new epoch cannot initialize")
	}
	pm.IsolatedPrefill.TokensPerSecond++
	history.Reconcile(capacity, time.Time{}, now.Add(3*time.Minute), time.Second)
	if sample, _ := history.Lookup("m"); !sample.ObservedAfter.IsZero() {
		t.Fatal("changed rate reused count")
	}
	history.Reconcile(nil, time.Time{}, now, time.Second)
	if history.Count() != 0 {
		t.Fatal("missing capacity did not reset evidence")
	}
}

func TestMalformedPerformanceMetadataFailsClosed(t *testing.T) {
	for _, invalid := range []protocol.PerformanceRateObservation{
		{TokensPerSecond: math.NaN(), SampleCount: 1},
		{TokensPerSecond: 20_001, SampleCount: 1},
		{TokensPerSecond: 100, SampleCount: 0},
		{TokensPerSecond: 100, SampleCount: 1, SampleAgeMS: -1},
		{TokensPerSecond: 100, SampleCount: 1, SampleAgeMS: math.MaxInt64},
	} {
		capacity := measurementCapacity()
		capacity.Slots[0].PerformanceMeasurements.IsolatedPrefill = &invalid
		capacityvalue.ClampBackendCapacity(testLogger(), "provider", capacity)
		history := &measurements.History{}
		history.Reconcile(capacity, time.Time{}, time.Now(), time.Second)
		if sample, _ := history.Lookup("m"); !sample.ObservedAfter.IsZero() {
			t.Fatalf("invalid sample fresh: %+v", invalid)
		}
	}
	capacity := measurementCapacity()
	pm := capacity.Slots[0].PerformanceMeasurements
	pm.Epoch = ""
	capacityvalue.ClampBackendCapacity(testLogger(), "provider", capacity)
	if capacity.Slots[0].PerformanceMeasurements == nil {
		t.Fatal("invalid metadata lost new-producer sentinel")
	}
	history := &measurements.History{}
	history.Reconcile(capacity, time.Time{}, time.Now(), time.Second)
	*capacity.Slots[0].Telemetry.IsolatedPrefillTPS++
	acceptedAt := time.Now()
	history.Reconcile(capacity, acceptedAt, time.Now(), time.Second)
	if sample, _ := history.Lookup("m"); !sample.ObservedAfter.IsZero() {
		t.Fatal("invalid explicit metadata fell back to changed EWMA")
	}
}

func TestNativeMediaPrefillIsRetainedWithoutChangingTextRates(t *testing.T) {
	capacity := measurementCapacity()
	pm := capacity.Slots[0].PerformanceMeasurements
	textRate := *pm.IsolatedPrefill
	media := protocol.PerformanceWorkloadBucket{Phase: "native_media_prefill",
		PromptTokenBucket: 4096, ContextTokenBucket: 4096, CacheState: "cold", Contention: "isolated",
		Observation: protocol.PerformanceRateObservation{TokensPerSecond: 834, SampleCount: 2, SampleAgeMS: 100}}
	pm.WorkloadBuckets = []protocol.PerformanceWorkloadBucket{media}
	capacityvalue.ClampBackendCapacity(testLogger(), "provider", capacity)
	if len(pm.WorkloadBuckets) != 1 || pm.WorkloadBuckets[0] != media || *pm.IsolatedPrefill != textRate {
		t.Fatal("native media evidence was discarded or replaced the text rate")
	}
	history := &measurements.History{}
	history.Reconcile(capacity, time.Time{}, time.Now(), time.Second)
	if sample, _ := history.Lookup("m"); sample.Rate != textRate.TokensPerSecond {
		t.Fatal("diagnostic media rate changed first-content text evidence")
	}
}
