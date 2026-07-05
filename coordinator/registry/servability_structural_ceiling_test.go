package registry

import "testing"

// The tier-2 fleet shed is STRUCTURAL: it compares the request against each
// provider's budget CEILING (resident active_token_budget_max / optimistic cold
// post-load estimate), never the live remaining budget. Transient fullness —
// the request fits a ceiling but not the fleet's current headroom — must stay
// servable so the capacity/queue path (queue-before-shed) owns it; only a
// request that could NEVER fit sheds. These tests replace the earlier
// live-subtract pins (TestPredictServableSubtractsCommitted,
// TestPredictServableQueuedTokensReduceLiveBudget) with the structural
// contract.

// TestPredictServableTransientFullnessServable: committed (active) tokens do
// NOT shrink the tier-2 ceiling. A 50k request against a 131072-ceiling
// provider with 100k already committed is BUSY, not unservable — under the
// live-subtract math it was shed as prompt_too_long before ever reaching the
// queue.
func TestPredictServableTransientFullnessServable(t *testing.T) {
	reg := New(testLogger())
	model := "structural-ceiling-model"
	// Resident provider: 131072 ceiling, 100000 already committed (live
	// remaining would be 31072).
	makeTokenBudgetProvider(t, reg, "busy", model, 100, 100_000, 131_072, 80)

	// 50k request exceeds the 31072 live remaining but fits the ceiling.
	v := reg.PredictServable(model, 49_744, 49_744, 256, 0, RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("50k request fits the 131072 ceiling (100k committed is transient fullness) — must be servable: %+v", v)
	}
	if v.Reason != "" {
		t.Fatalf("reason = %q, want empty for a servable verdict", v.Reason)
	}
	if v.FleetMaxBudget != 131_072 {
		t.Fatalf("FleetMaxBudget = %d, want 131072 (the structural ceiling, not live remaining)", v.FleetMaxBudget)
	}

	// Structural impossibility still sheds: bigger than the ceiling itself.
	over := reg.PredictServable(model, 131_072, 131_072, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("131328-token request can never fit the 131072 ceiling — must shed: %+v", over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
	}
}

// TestPredictServableQueuedTokensDoNotReduceCeiling: queued (planner-pending)
// tokens are transient commitments exactly like active ones — they drain, so
// they must not shrink the structural ceiling either. Per-provider admission
// (providerBudgetFits / freeMemoryAdmits) still counts them, which is what
// routes the request into the queue instead of onto the full provider.
func TestPredictServableQueuedTokensDoNotReduceCeiling(t *testing.T) {
	reg := New(testLogger())
	model := "queued-ceiling-model"
	p := makeTokenBudgetProvider(t, reg, "queued", model, 100, 0, 131_072, 80)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 100_000
	p.mu.Unlock()

	// 50k request exceeds the 31072 live remaining (queued counted) but fits
	// the 131072 ceiling → servable, queue owns the wait.
	v := reg.PredictServable(model, 49_744, 49_744, 256, 0, RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("50k request fits the 131072 ceiling (100k queued is transient fullness) — must be servable: %+v", v)
	}
	if v.FleetMaxBudget != 131_072 {
		t.Fatalf("FleetMaxBudget = %d, want 131072 (queued tokens must not reduce the ceiling)", v.FleetMaxBudget)
	}

	// Over the ceiling itself still sheds regardless of queue state.
	over := reg.PredictServable(model, 131_072, 131_072, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("over-ceiling request must shed: %+v", over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
	}
}
