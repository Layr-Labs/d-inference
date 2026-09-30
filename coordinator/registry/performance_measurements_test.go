package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"math"
	"testing"
	"time"
)

func measurementCapacity() *protocol.BackendCapacity {
	rate, ready := 2000.0, true
	return &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "idle", ObservedDecodeTPS: 100,
		Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &rate, EWMAInitialized: &ready},
		PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: "engine-a",
			IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 2000, SampleCount: 1, SampleAgeMS: 2000},
			Decode:          &protocol.PerformanceRateObservation{TokensPerSecond: 100, SampleCount: 3, SampleAgeMS: 1000}}}}}
}

func TestExplicitPerformanceMeasurementFreshness(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	p := &Provider{}
	capacity := measurementCapacity()
	p.reconcileFirstContentMeasurementsLocked(capacity, now)
	sample := p.firstContentMeasurements["m"]
	if !sample.observedAfter.Equal(now.Add(-3*time.Second)) || !sample.decodeObservedAfter.Equal(now.Add(-2*time.Second)) {
		t.Fatalf("fresh first report lost explicit observation: %+v", sample)
	}
	// Replayed metadata with a new capacity sequence cannot renew either rate.
	p.reconcileFirstContentMeasurementsLocked(capacity, now.Add(time.Minute))
	if got := p.firstContentMeasurements["m"]; !got.observedAfter.Equal(sample.observedAfter) || !got.decodeObservedAfter.Equal(sample.decodeObservedAfter) {
		t.Fatalf("same counts rejuvenated: %+v", got)
	}
	pm := capacity.Slots[0].PerformanceMeasurements
	pm.IsolatedPrefill.SampleCount++
	p.reconcileFirstContentMeasurementsLocked(capacity, now.Add(time.Minute))
	got := p.firstContentMeasurements["m"]
	if !got.observedAfter.Equal(now.Add(57*time.Second)) || !got.decodeObservedAfter.Equal(sample.decodeObservedAfter) {
		t.Fatalf("equal new prefill did not independently refresh: %+v", got)
	}
	// Reset counters are allowed only with a different engine lifetime.
	pm.IsolatedPrefill.SampleCount = 1
	p.reconcileFirstContentMeasurementsLocked(capacity, now.Add(2*time.Minute))
	if !p.firstContentMeasurements["m"].observedAfter.IsZero() {
		t.Fatal("regressed count retained freshness")
	}
	pm.Epoch = "engine-b"
	p.reconcileFirstContentMeasurementsLocked(capacity, now.Add(2*time.Minute))
	if p.firstContentMeasurements["m"].observedAfter.IsZero() {
		t.Fatal("new epoch cannot initialize")
	}
	pm.IsolatedPrefill.TokensPerSecond++
	p.reconcileFirstContentMeasurementsLocked(capacity, now.Add(3*time.Minute))
	if !p.firstContentMeasurements["m"].observedAfter.IsZero() {
		t.Fatal("changed rate reused count")
	}
	p.reconcileFirstContentMeasurementsLocked(nil, now)
	if len(p.firstContentMeasurements) != 0 {
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
		clampBackendCapacity(testLogger(), "provider", capacity)
		p := &Provider{}
		p.reconcileFirstContentMeasurementsLocked(capacity)
		if !p.firstContentMeasurements["m"].observedAfter.IsZero() {
			t.Fatalf("invalid sample fresh: %+v", invalid)
		}
	}
	capacity := measurementCapacity()
	pm := capacity.Slots[0].PerformanceMeasurements
	pm.Epoch = ""
	clampBackendCapacity(testLogger(), "provider", capacity)
	if capacity.Slots[0].PerformanceMeasurements == nil {
		t.Fatal("invalid metadata lost new-producer sentinel")
	}
	p := &Provider{}
	p.reconcileFirstContentMeasurementsLocked(capacity)
	*capacity.Slots[0].Telemetry.IsolatedPrefillTPS++
	p.CapacityAcceptedAt = time.Now()
	p.reconcileFirstContentMeasurementsLocked(capacity)
	if !p.firstContentMeasurements["m"].observedAfter.IsZero() {
		t.Fatal("invalid explicit metadata fell back to changed EWMA")
	}
}

func TestPerformanceWorkloadBucketsAreBoundedAndDetached(t *testing.T) {
	capacity := measurementCapacity()
	pm := capacity.Slots[0].PerformanceMeasurements
	valid := protocol.PerformanceWorkloadBucket{Phase: "prefill", PromptTokenBucket: 1024, ContextTokenBucket: 4096, CacheState: "cold", Contention: "isolated", Observation: *pm.IsolatedPrefill}
	for range 100 {
		pm.WorkloadBuckets = append(pm.WorkloadBuckets, valid)
	}
	clampBackendCapacity(testLogger(), "provider", capacity)
	if len(pm.WorkloadBuckets) != 32 {
		t.Fatal("bucket payload unbounded")
	}
	var clone protocol.BackendSlotCapacity
	cloneBackendSlot(&clone, &capacity.Slots[0])
	clone.PerformanceMeasurements.IsolatedPrefill.SampleCount = 99
	clone.PerformanceMeasurements.WorkloadBuckets[0].Observation.SampleCount = 98
	if pm.IsolatedPrefill.SampleCount != 1 || pm.WorkloadBuckets[0].Observation.SampleCount != 1 {
		t.Fatal("measurement clone aliased heartbeat")
	}
}

func TestPerformanceWorkloadBucketsAcceptOnlyClosedMetadata(t *testing.T) {
	capacity := measurementCapacity()
	pm := capacity.Slots[0].PerformanceMeasurements
	valid := protocol.PerformanceWorkloadBucket{Phase: "prefill", PromptTokenBucket: 1024, ContextTokenBucket: 4096, CacheState: "cold", Contention: "isolated", Observation: *pm.IsolatedPrefill}
	for _, mutate := range []func(*protocol.PerformanceWorkloadBucket){
		func(b *protocol.PerformanceWorkloadBucket) { b.Phase = "CONTENT_SENTINEL" },
		func(b *protocol.PerformanceWorkloadBucket) { b.CacheState = "CONTENT_SENTINEL" },
		func(b *protocol.PerformanceWorkloadBucket) { b.Contention = "CONTENT_SENTINEL" },
		func(b *protocol.PerformanceWorkloadBucket) { b.PromptTokenBucket = 1234 },
		func(b *protocol.PerformanceWorkloadBucket) { b.ContextTokenBucket = 1234 },
	} {
		invalid := valid
		mutate(&invalid)
		pm.WorkloadBuckets = append(pm.WorkloadBuckets, invalid)
	}
	pm.WorkloadBuckets = append(pm.WorkloadBuckets, valid)
	clampBackendCapacity(testLogger(), "provider", capacity)
	if len(pm.WorkloadBuckets) != 1 || pm.WorkloadBuckets[0] != valid {
		t.Fatalf("open-ended metadata accepted: %+v", pm.WorkloadBuckets)
	}
}
