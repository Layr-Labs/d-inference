package registry

import (
	"fmt"
	"testing"
	"time"
)

func TestInferenceErrorMapsBounded(t *testing.T) {
	r := New(testLogger())
	// Trip the breaker for >1024 distinct dead identities, then let everything
	// expire — the gate sweep must drop every idle gate, while a connected
	// provider's gate keeps its (pruned) state.
	for i := 0; i < 1100; i++ {
		id := fmt.Sprintf("dead-provider-%d", i)
		r.RecordInferenceError(id, "m", 500, "base")
		r.RecordInferenceError(id, "m", 500, "base")
	}
	if n := r.gateCount(); n < 1000 {
		t.Fatalf("setup produced too few distinct gates: %d", n)
	}
	live := makeSchedulerProvider(t, r, "live", "m", 50)
	r.RecordInferenceError(live.ID, "m", 500, "base")

	future := time.Now().Add(gateIdleGrace + inferenceErrorCooldownTTL + time.Second)
	r.sweepGates(future)

	if after := r.gateCount(); after != 1 {
		t.Fatalf("sweep should leave only the live provider's gate, got %d", after)
	}
	g := r.faults.StatusForSession(live.ID, "m", "base")

	if !g.Found {
		t.Fatal("the connected provider's gate must never be swept")
	}
	if g.InferenceStrikeKeys != 0 || g.InferenceCooldownKeys != 0 {
		t.Fatalf("expired strikes/cooldowns must be pruned from a live gate: strikes=%d cooldowns=%d",
			g.InferenceStrikeKeys, g.InferenceCooldownKeys)
	}
}

// End-to-end through the production dispatch hot path (ReserveProviderEx): a
// pair quarantined by the inference-error breaker must be structurally
// excluded from candidates so selection falls to a healthy provider, a fully
// quarantined fleet yields no selection, and a success restores the pair.
func TestReserveProviderExSkipsInferenceErrorCooldown(t *testing.T) {
	reg := New(testLogger())
	model := "inference-error-model"
	bad := makeSchedulerProvider(t, reg, "bad", model, 200)
	good := makeSchedulerProvider(t, reg, "good", model, 50)

	req := func(id string) *PendingRequest {
		return &PendingRequest{RequestID: id, Model: model, RequestedMaxTokens: 128}
	}

	// These requests carry no traits, so they route on the "base" shape; the
	// breaker must be recorded on the same shape the scheduler consults.
	const shape = "base"

	// 4xx (client-shape) and 503 (capacity/lifecycle) errors must not
	// deroute anyone.
	reg.RecordInferenceError(bad.ID, model, 400, shape)
	reg.RecordInferenceError(bad.ID, model, 429, shape)
	reg.RecordInferenceError(bad.ID, model, 503, shape)
	if _, decision := reg.ReserveProviderEx(model, req("r-4xx")); decision.CandidateCount != 2 {
		t.Fatalf("4xx errors must not exclude a provider: CandidateCount=%d, want 2", decision.CandidateCount)
	}
	bad.RemovePending("r-4xx")
	good.RemovePending("r-4xx")

	// Two 5xx quarantine the bad pair: selection must fall to the other one.
	reg.RecordInferenceError(bad.ID, model, 500, shape)
	if !reg.RecordInferenceError(bad.ID, model, 500, shape) {
		t.Fatal("second 5xx should report the transition into cooldown")
	}
	selected, decision := reg.ReserveProviderEx(model, req("r1"))
	if selected == nil {
		t.Fatal("selection must fall to the healthy provider, got nil")
	}
	if selected.ID != good.ID {
		t.Fatalf("selected %q, want healthy provider %q", selected.ID, good.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (cooled pair structurally excluded)", decision.CandidateCount)
	}
	good.RemovePending("r1")

	// Quarantine the second provider too (502 = disconnect flush): nothing serves.
	reg.RecordInferenceError(good.ID, model, 502, shape)
	reg.RecordInferenceError(good.ID, model, 502, shape)
	if selected, _ := reg.ReserveProviderEx(model, req("r2")); selected != nil {
		t.Fatalf("selected %q, want nil when every pair is quarantined", selected.ID)
	}

	// A served request restores the pair immediately.
	reg.RecordInferenceSuccess(bad.ID, model, shape)
	selected, _ = reg.ReserveProviderEx(model, req("r3"))
	if selected == nil || selected.ID != bad.ID {
		t.Fatalf("after success-clear expected %q to serve again, got %v", bad.ID, selected)
	}
}
