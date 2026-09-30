package registry

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPrefillMedianIsKeyedAndBounded(t *testing.T) {
	r := NewTPSRegistry()
	if got := r.PrefillMedian("m", "M3"); got != 0 {
		t.Fatalf("empty store: median %v, want 0", got)
	}
	for _, tps := range []float64{900, 1500, 2100} {
		r.RecordPrefill("m", "M3", tps)
	}
	r.RecordPrefill("m", "M4", 4000)
	for _, bad := range []float64{0, -1, math.NaN(), math.Inf(1), maxPrefillTPS + 1} {
		r.RecordPrefill("m", "M3", bad)
	}
	r.RecordPrefill("", "M3", 10)
	if got := r.PrefillMedian("m", "M3"); got != 1500 {
		t.Fatalf("M3 median %v, want 1500 (invalid rates must not count)", got)
	}
	if got := r.PrefillMedian("m", "M4"); got != 4000 {
		t.Fatalf("M4 median %v, want its own samples only", got)
	}
	if got := r.Median("m", "M3"); got != 0 {
		t.Fatalf("decode median %v, want 0: prefill samples must not enter the decode store", got)
	}
	// The ring keeps the last 50 samples, the same as the decode store.
	for range 50 {
		r.RecordPrefill("m", "M3", 3000)
	}
	if got := r.PrefillMedian("m", "M3"); got != 3000 {
		t.Fatalf("median after the ring filled %v, want 3000", got)
	}
}

func TestZeroValuePrefillRegistryRecords(t *testing.T) {
	var r TPSRegistry
	r.RecordPrefill("m", "M3", 1200)
	if got := r.PrefillMedian("m", "M3"); got != 1200 {
		t.Fatalf("zero-value registry median %v, want 1200", got)
	}
}

// The heartbeat feeds the fleet prefill median with the isolated prefill rate
// that the routing snapshot would read for the same slot.
func TestHeartbeatRecordsIsolatedPrefillMedian(t *testing.T) {
	zero := int64(0)
	legacy := func(rate float64, initialized bool) *protocol.SlotTelemetry {
		return &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
			IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
	}
	cases := []struct {
		name string
		slot protocol.BackendSlotCapacity
		want float64
	}{
		{"legacy_initialized", protocol.BackendSlotCapacity{Telemetry: legacy(1500, true)}, 1500},
		{"legacy_uninitialized", protocol.BackendSlotCapacity{Telemetry: legacy(1500, false)}, 0},
		{"no_telemetry", protocol.BackendSlotCapacity{ObservedPrefillTPS: 1500}, 0},
		{"explicit_replaces_legacy", protocol.BackendSlotCapacity{
			Telemetry: legacy(1500, true),
			PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: "e",
				IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: 2500, SampleCount: 3}},
		}, 2500},
		{"explicit_without_prefill", protocol.BackendSlotCapacity{
			Telemetry:               legacy(1500, true),
			PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: "e"},
		}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			makeSchedulerProvider(t, reg, "box", gemmaBuild, 93)
			slot := tc.slot
			slot.Model, slot.State = gemmaBuild, "idle"
			reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{slot}))
			if got := reg.tpsRegistry.PrefillMedian(gemmaBuild, "M3"); got != tc.want {
				t.Fatalf("prefill median %v, want %v", got, tc.want)
			}
		})
	}
}
