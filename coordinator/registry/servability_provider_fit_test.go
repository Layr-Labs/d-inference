package registry

import "testing"

// Per-provider budget-fit coverage for providerBudgetFits — the helper that
// mirrors the provider's own admission math (warm: activeUsed + queued +
// request ≤ tokenBudgetMax; cold: request ≤ post-load KV budget) so the
// scheduler's free-memory gate stops admitting requests the provider is
// guaranteed to reject with token_budget_exhausted / a load-headroom 503.

// TestPredictServableColdWeightFitInsufficientBudgetSheds is the fleet-level
// counterpart of the cold-load gap: the ONLY eligible provider is a cold node
// whose hardware fits the model (min_ram passes, weights load) but whose
// post-load KV budget cannot hold the request. Every budget is KNOWN, so
// tier-2 must shed (prompt_too_long) instead of admitting into a guaranteed
// provider-side rejection.
func TestPredictServableColdWeightFitInsufficientBudgetSheds(t *testing.T) {
	reg := New(testLogger())
	model := "cold-budget-model"
	// 28 GB weights on a 48 GB node running v0.8.0: min_ram 36 ≤ 48 passes the
	// hardware gate, and the post-load budget is
	// coldTokenBudgetEstimate(48, 28, 0, "0.8.0", "") = 17200
	// (see TestColdTokenBudgetEstimate case (b2)).
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 28, MinRAMGB: 36}})
	cold := makeWarmPoolColdProvider(t, reg, "cold-48gb", model, 80, 48, 0)
	cold.mu.Lock()
	cold.Version = "0.8.0"
	cold.mu.Unlock()

	budget := coldTokenBudgetEstimate(48, 28, 0, "0.8.0", "")
	if budget <= 0 {
		t.Fatalf("cold budget = %d, want > 0", budget)
	}

	over := reg.PredictServable(model, 30_000, 30_000, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("30k request vs %d-token cold budget reported servable: %+v", budget, over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
	}
	if over.FleetMaxBudget != budget {
		t.Fatalf("FleetMaxBudget = %d, want %d (cold post-load estimate)", over.FleetMaxBudget, budget)
	}

	within := reg.PredictServable(model, 10_000, 10_000, 256, 0, RequestTraits{}, false)
	if !within.Servable {
		t.Fatalf("10k request vs %d-token cold budget reported unservable: %+v", budget, within)
	}
}
