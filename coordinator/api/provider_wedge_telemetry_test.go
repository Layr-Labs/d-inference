package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestBackendWedgeSignalsExtraction verifies the heartbeat → wedge-signal
// extraction: legacy/idle slots (all zero) produce nothing, instrumented slots
// surface their counters, and a nil/empty heartbeat is safe.
func TestBackendWedgeSignalsExtraction(t *testing.T) {
	if got := backendWedgeSignals(nil); got != nil {
		t.Fatalf("nil heartbeat should yield no signals, got %+v", got)
	}
	if got := backendWedgeSignals(&protocol.HeartbeatMessage{}); got != nil {
		t.Fatalf("heartbeat without backend capacity should yield no signals, got %+v", got)
	}

	hb := &protocol.HeartbeatMessage{
		BackendCapacity: &protocol.BackendCapacity{
			Slots: []protocol.BackendSlotCapacity{
				// Legacy / freshly-idle: reports no engine-health signal → skipped.
				{Model: "legacy", State: "idle"},
				// Wedged: admits climbing, 0 first tokens, steps frozen.
				{
					Model:                "gpt-oss-20b",
					State:                "idle",
					StepsExecuted:        1000,
					Admits:               5,
					FirstTokensEmitted:   0,
					SecondsSinceLastStep: 30,
					WedgeSuspected:       true,
				},
				// Healthy-but-instrumented: has steps/admits but not wedged.
				{
					Model:              "qwen",
					State:              "running",
					StepsExecuted:      5000,
					Admits:             20,
					FirstTokensEmitted: 20,
				},
			},
		},
	}

	got := backendWedgeSignals(hb)
	if len(got) != 2 {
		t.Fatalf("expected 2 instrumented slots (legacy skipped), got %d: %+v", len(got), got)
	}
	if got[0].Model != "gpt-oss-20b" || !got[0].WedgeSuspected {
		t.Fatalf("expected first signal to be the wedged gpt-oss slot, got %+v", got[0])
	}
	if got[0].Admits != 5 || got[0].FirstTokensEmitted != 0 {
		t.Fatalf("wedge counters mismatch: %+v", got[0])
	}
	if got[1].Model != "qwen" || got[1].WedgeSuspected {
		t.Fatalf("expected second signal to be the healthy qwen slot, got %+v", got[1])
	}
}

// TestRecordBackendWedgeTelemetryNilSafe verifies the emitter is safe with a
// Server that has no Datadog client wired (ddIncr is a no-op then), so the
// heartbeat path never panics on a non-DD deployment.
func TestRecordBackendWedgeTelemetryNilSafe(t *testing.T) {
	s := &Server{}
	// Must not panic with nil dd and a wedged slot.
	s.recordBackendWedgeTelemetry(&protocol.HeartbeatMessage{
		BackendCapacity: &protocol.BackendCapacity{
			Slots: []protocol.BackendSlotCapacity{
				{Model: "m", State: "idle", Admits: 3, WedgeSuspected: true},
			},
		},
	})
}
