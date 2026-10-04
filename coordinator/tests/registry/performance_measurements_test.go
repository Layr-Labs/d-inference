package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func measurementCapacity() *protocol.BackendCapacity {
	rate, ready := 2000.0, true
	return &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "idle", ObservedDecodeTPS: 100,
		Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &rate, EWMAInitialized: &ready},
		PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: "engine-a",
			IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 2000, SampleCount: 1, SampleAgeMS: 2000},
			Decode:          &protocol.PerformanceRateObservation{TokensPerSecond: 100, SampleCount: 3, SampleAgeMS: 1000}}}}}
}

func TestPerformanceWorkloadBucketsAreBoundedAndDetached(t *testing.T) {
	capacity := measurementCapacity()
	pm := capacity.Slots[0].PerformanceMeasurements
	valid := protocol.PerformanceWorkloadBucket{Phase: "prefill", PromptTokenBucket: 1024, ContextTokenBucket: 4096, CacheState: "cold", Contention: "isolated", Observation: *pm.IsolatedPrefill}
	for range 100 {
		pm.WorkloadBuckets = append(pm.WorkloadBuckets, valid)
	}
	capacityvalue.ClampBackendCapacity(testLogger(), "provider", capacity)
	if len(pm.WorkloadBuckets) != 32 {
		t.Fatal("bucket payload unbounded")
	}
	var clone protocol.BackendSlotCapacity
	capacityvalue.CloneBackendSlot(&clone, &capacity.Slots[0])
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
	capacityvalue.ClampBackendCapacity(testLogger(), "provider", capacity)
	if len(pm.WorkloadBuckets) != 1 || pm.WorkloadBuckets[0] != valid {
		t.Fatalf("open-ended metadata accepted: %+v", pm.WorkloadBuckets)
	}
}
