package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// reportMeasuredFirstContentEvidence establishes bounded sample ages using two
// accepted frames with changed prefill and decode EWMAs. It preserves the
// provider's existing physical-capacity fixture.
func reportMeasuredFirstContentEvidence(t *testing.T, reg *registry.Registry, id, model string, prefill, decode float64) {
	t.Helper()
	p := reg.GetProvider(id)
	if p == nil {
		t.Fatalf("missing provider %s", id)
	}
	capacity := p.BackendCapacitySnapshot()
	if capacity == nil {
		t.Fatal("measured fixture requires capacity")
	}
	seq := capacity.CapacitySeq
	for i, factor := range []float64{0.99, 1} {
		capacity = p.BackendCapacitySnapshot()
		capacity.CapacitySeq = seq + uint64(i+1)
		for j := range capacity.Slots {
			slot := &capacity.Slots[j]
			if slot.Model != model {
				continue
			}
			rate, initialized := prefill*factor, true
			slot.State = "idle"
			slot.ObservedDecodeTPS = decode * factor
			slot.ObservedPrefillTPS = rate
			slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64), IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
		}
		if !reg.Heartbeat(id, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
			t.Fatal("fresh sample rejected")
		}
	}
}
