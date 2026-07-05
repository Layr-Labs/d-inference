package registry

import "testing"

// Per-provider budget-fit coverage for providerBudgetFits — the helper that
// mirrors the provider's own admission math (warm: activeUsed + queued +
// request ≤ tokenBudgetMax; cold: request ≤ post-load KV budget) so the
// scheduler's free-memory gate stops admitting requests the provider is
// guaranteed to reject with token_budget_exhausted / a load-headroom 503.

// TestProviderBudgetFitsWarmSlotLiveBudget: a resident slot reporting
// activeTokenBudgetMax=B with used+queued=U admits a request iff
// prompt+max_tokens ≤ B−U — exactly the provider's submit gate.
func TestProviderBudgetFitsWarmSlotLiveBudget(t *testing.T) {
	snap := routingSnapshot{
		activeTokenBudgetMax:  32_768,
		activeTokenBudgetUsed: 20_000,
		queuedTokenBudget:     4_000,
		modelLoaded:           true,
	}
	// Live remaining budget = 32768 - 20000 - 4000 = 8768.

	if fits, known := providerBudgetFits(snap, 8_000, 1_000); !known || fits {
		t.Fatalf("9000-token request vs 8768 live budget = (fits=%v, known=%v), want (false, true)", fits, known)
	}
	if fits, known := providerBudgetFits(snap, 8_000, 512); !known || !fits {
		t.Fatalf("8512-token request vs 8768 live budget = (fits=%v, known=%v), want (true, true)", fits, known)
	}
	// Exact boundary is a fit (provider gate is `>` to reject, `<=` to admit).
	if fits, known := providerBudgetFits(snap, 8_512, 256); !known || !fits {
		t.Fatalf("exact-boundary 8768-token request = (fits=%v, known=%v), want (true, true)", fits, known)
	}

	// reqMaxTokens <= 0 normalizes to defaultRequestedMaxTokens (256), matching
	// the pending-budget accounting: 8512+256 = 8768 fits, 8513+256 does not.
	if fits, _ := providerBudgetFits(snap, 8_512, 0); !fits {
		t.Fatal("reqMax=0 must default to defaultRequestedMaxTokens (8512+256=8768 fits)")
	}
	if fits, _ := providerBudgetFits(snap, 8_513, 0); fits {
		t.Fatal("reqMax=0 must default to defaultRequestedMaxTokens (8513+256=8769 must not fit)")
	}
	// Negative prompt clamps to 0.
	if fits, known := providerBudgetFits(snap, -5, 256); !known || !fits {
		t.Fatalf("negative prompt = (fits=%v, known=%v), want (true, true)", fits, known)
	}
}

// TestProviderBudgetFitsColdLoadPostLoadBudget pins the cold-load gap: a
// provider whose free_for_load_gb fits the PADDED WEIGHTS (so the current
// weight-only coordinator gate admits, and the provider load succeeds) but
// whose post-load KV budget cannot hold the request. The provider's load gate
// only guarantees ~1 GiB of serveable KV above the weights
// (UnifiedMemoryCap.loadHeadroomBytes), so the load succeeds and the FIRST
// submit rejects with token_budget_exhausted → the admit-then-503 shape. The
// aligned math (request vs coldTokenBudgetEstimate) must call it unservable.
func TestProviderBudgetFitsColdLoadPostLoadBudget(t *testing.T) {
	// gemma-4-26b shape: 28 GB catalog weights on a 48 GB box. Padded weights
	// = 28 × ~1.1176 ≈ 31.3 GiB ≤ free_for_load 32 → the weight gate admits.
	freeForLoad := 32.0
	snap := routingSnapshot{
		totalMemoryGB:   48,
		modelSizeGB:     28,
		freeForLoadGB:   &freeForLoad,
		availableOnDisk: true,
	}
	if admit, reported := reportedFreeForLoadAdmits(snap.modelSizeGB, snap.freeForLoadGB); !reported || !admit {
		t.Fatalf("precondition: weight-only cold gate must admit (admit=%v, reported=%v)", admit, reported)
	}

	// Post-load budget per the provider's own headroom math:
	// (0.90×48 − paddedWeights − 3 GB activation reserve) / 400000 B/token.
	budget := coldTokenBudgetEstimate(snap.totalMemoryGB, snap.modelSizeGB, 0)
	if budget <= 0 || budget >= 30_000 {
		t.Fatalf("cold post-load budget = %d, want a positive value below the 30k request", budget)
	}

	// A 30k-token request loads fine but can never be served post-load.
	if fits, known := providerBudgetFits(snap, 30_000, 256); !known || fits {
		t.Fatalf("30k request vs %d-token post-load budget = (fits=%v, known=%v), want (false, true)", budget, fits, known)
	}
	// A request within the post-load budget fits.
	if fits, known := providerBudgetFits(snap, 10_000, 256); !known || !fits {
		t.Fatalf("10k request vs %d-token post-load budget = (fits=%v, known=%v), want (true, true)", budget, fits, known)
	}
}

// TestProviderBudgetFitsFailsOpenOnUnknown: when the budget cannot be computed
// the helper must report known=false and fit=true so callers keep today's
// behavior (fail open) rather than shedding on missing data.
func TestProviderBudgetFitsFailsOpenOnUnknown(t *testing.T) {
	// Resident legacy slot with no reported budget.
	if fits, known := providerBudgetFits(routingSnapshot{modelLoaded: true}, 1_000_000, 256); known || !fits {
		t.Fatalf("legacy resident slot = (fits=%v, known=%v), want (true, false)", fits, known)
	}
	// Cold slot missing memory/size data.
	if fits, known := providerBudgetFits(routingSnapshot{modelSizeGB: 28}, 1_000_000, 256); known || !fits {
		t.Fatalf("cold slot missing memory = (fits=%v, known=%v), want (true, false)", fits, known)
	}
	if fits, known := providerBudgetFits(routingSnapshot{totalMemoryGB: 48}, 1_000_000, 256); known || !fits {
		t.Fatalf("cold slot missing size = (fits=%v, known=%v), want (true, false)", fits, known)
	}
}

// TestPredictServableColdWeightFitInsufficientBudgetSheds is the fleet-level
// counterpart of the cold-load gap: the ONLY eligible provider is a cold node
// whose hardware fits the model (min_ram passes, weights load) but whose
// post-load KV budget cannot hold the request. Every budget is KNOWN, so
// tier-2 must shed (prompt_too_long) instead of admitting into a guaranteed
// provider-side rejection.
func TestPredictServableColdWeightFitInsufficientBudgetSheds(t *testing.T) {
	reg := New(testLogger())
	model := "cold-budget-model"
	// 28 GB weights on a 48 GB node: min_ram 36 ≤ 48 passes the hardware gate,
	// and the post-load budget is coldTokenBudgetEstimate(48, 28, 0) ≈ 23.9k.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 28, MinRAMGB: 36}})
	makeWarmPoolColdProvider(t, reg, "cold-48gb", model, 80, 48, 0)

	budget := coldTokenBudgetEstimate(48, 28, 0)
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

// TestPredictServableQueuedTokensReduceLiveBudget: queued (planner-pending)
// tokens count against the live budget exactly like active ones — the provider
// admission sums both, so the fleet tier must too.
func TestPredictServableQueuedTokensReduceLiveBudget(t *testing.T) {
	reg := New(testLogger())
	model := "queued-budget-model"
	p := makeTokenBudgetProvider(t, reg, "queued", model, 100, 0, 131_072, 80)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 100_000
	p.mu.Unlock()
	// Live remaining = 131072 - 0 - 100000 = 31072.

	over := reg.PredictServable(model, 49_744, 49_744, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("50k request must be unservable against 31072 live budget (queued counted): %+v", over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
	}

	within := reg.PredictServable(model, 19_744, 19_744, 256, 0, RequestTraits{}, false)
	if !within.Servable {
		t.Fatalf("20k request must be servable against 31072 live budget: %+v", within)
	}
}
