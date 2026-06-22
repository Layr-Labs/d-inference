package registry

import "testing"

// C3: PredictServable's budget tier subtracts committed (active+queued) tokens, so
// the shed reflects LIVE remaining headroom — a request that fits the idle ceiling
// but not the live budget is now (correctly) unservable.
func TestPredictServableSubtractsCommitted(t *testing.T) {
	reg := New(testLogger())
	model := "live-budget-model"
	// Resident provider: 131072 max, 100000 already committed → 31072 live remaining.
	makeTokenBudgetProvider(t, reg, "busy", model, 100, 100_000, 131_072, 80)

	// 50k request fits the idle ceiling (131072) but NOT the 31072 live budget.
	// Pre-fix (raw structural ceiling) this was servable; now unservable.
	over := reg.PredictServable(model, 49_744, 49_744, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("50k request must be unservable against 31072 live budget: %+v", over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
	}

	// 20k request fits the live remaining → servable.
	within := reg.PredictServable(model, 19_744, 19_744, 256, 0, RequestTraits{}, false)
	if !within.Servable {
		t.Fatalf("20k request must be servable against 31072 live budget: %+v", within)
	}
}
