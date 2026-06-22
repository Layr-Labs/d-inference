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
				// Wedged: admits climbing, 0 first tokens, steps frozen, and the
				// blocking eval has been running 11s (the smoking gun).
				{
					Model:                "gpt-oss-20b",
					State:                "idle",
					StepsExecuted:        1000,
					Admits:               5,
					FirstTokensEmitted:   0,
					SecondsSinceLastStep: 30,
					WedgeSuspected:       true,
					EvalInFlightMs:       11000,
				},
				// Healthy-but-instrumented: has steps/admits but not wedged.
				{
					Model:              "qwen",
					State:              "running",
					StepsExecuted:      5000,
					Admits:             20,
					FirstTokensEmitted: 20,
				},
				// Only an in-flight eval reported (no other counters) — must still
				// be surfaced so a developing wedge isn't skipped.
				{
					Model:          "gemma",
					State:          "idle",
					EvalInFlightMs: 3000,
				},
			},
		},
	}

	got := backendWedgeSignals(hb)
	if len(got) != 3 {
		t.Fatalf("expected 3 instrumented slots (legacy skipped), got %d: %+v", len(got), got)
	}
	if got[0].Model != "gpt-oss-20b" || !got[0].WedgeSuspected {
		t.Fatalf("expected first signal to be the wedged gpt-oss slot, got %+v", got[0])
	}
	if got[0].Admits != 5 || got[0].FirstTokensEmitted != 0 || got[0].EvalInFlightMs != 11000 {
		t.Fatalf("wedge counters mismatch: %+v", got[0])
	}
	if got[1].Model != "qwen" || got[1].WedgeSuspected {
		t.Fatalf("expected second signal to be the healthy qwen slot, got %+v", got[1])
	}
	if got[2].Model != "gemma" || got[2].EvalInFlightMs != 3000 {
		t.Fatalf("expected third signal to be the eval-in-flight gemma slot, got %+v", got[2])
	}
}

// TestProviderWideEvalInFlightLong verifies eval_in_flight is treated as a
// PROVIDER-WIDE signal (max across slots), not per-slot: `eval_in_flight_ms` is
// the process-global EvalProbe value copied onto every slot, so the "long"
// decision must be made once from the max — never summed and never fired once
// per loaded model.
func TestProviderWideEvalInFlightLong(t *testing.T) {
	// Three slots each BELOW the threshold individually; a buggy per-slot/summing
	// emitter would cross the threshold (3×800=2400 ≥ 2000), but the correct
	// max-based decision (800 < 2000) does not.
	belowEach := []backendWedgeSignal{
		{Model: "a", EvalInFlightMs: 800},
		{Model: "b", EvalInFlightMs: 800},
		{Model: "c", EvalInFlightMs: 800},
	}
	if providerWideEvalInFlightLong(belowEach) {
		t.Fatalf("3 slots of 800ms must NOT trip (max=800 < %d), got long=true", evalInFlightLongMs)
	}

	// One stalled eval (process-global, copied onto every slot) ⇒ exactly one
	// provider-wide decision regardless of how many slots carry it.
	stalled := []backendWedgeSignal{
		{Model: "a", EvalInFlightMs: 11000},
		{Model: "b", EvalInFlightMs: 11000},
		{Model: "c", EvalInFlightMs: 11000},
	}
	if !providerWideEvalInFlightLong(stalled) {
		t.Fatal("3 slots carrying the same 11s in-flight eval must trip (max ≥ threshold)")
	}
	if !providerWideEvalInFlightLong(stalled[:1]) {
		t.Fatal("a single 11s in-flight eval slot must trip the same way (provider-wide)")
	}
	if providerWideEvalInFlightLong(nil) {
		t.Fatal("no slots must not trip")
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
