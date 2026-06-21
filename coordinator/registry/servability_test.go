package registry

import "testing"

// TestColdTokenBudgetEstimate pins the pure cold post-load KV-budget estimator.
// The formula is:
//
//	kvHeadroomGB = servabilityCapFraction*total - size*coldLoadCatalogGBToMemGiB - servabilityActivationReserveGB
//	tokens       = int64(kvHeadroomGB * bytesPerGB / kvBytesPerToken)   // kvBytesPerToken<=0 → 400000
//
// with servabilityCapFraction=0.90, servabilityActivationReserveGB=3.0,
// coldLoadCatalogGBToMemGiB≈1.1175870895385742, bytesPerGB=1<<30.
func TestColdTokenBudgetEstimate(t *testing.T) {
	// (a) Roomy node: total=64, size=12, kvpt=400000.
	//   padded   = 12 * 1.1175870895385742           = 13.41104507446289
	//   headroom = 0.90*64 - 13.41104507446289 - 3.0 = 41.18895492553711 GB
	//   tokens   = int64(41.18895492553711 * 2^30 / 400000) = 110565
	const wantRoomy = int64(110565)
	if got := coldTokenBudgetEstimate(64, 12, 400000); got != wantRoomy {
		t.Fatalf("roomy estimate = %d, want %d", got, wantRoomy)
	}
	if got := coldTokenBudgetEstimate(64, 12, 400000); got <= 0 {
		t.Fatalf("roomy estimate = %d, want > 0", got)
	}

	// (b) Tiny node: weights (padded) + activation reserve exceed 90% of the
	// 8 GB cap, so there is no KV headroom at all → 0 (never negative).
	if got := coldTokenBudgetEstimate(8, 12, 400000); got != 0 {
		t.Fatalf("tiny-node estimate = %d, want 0 (weights+reserve exceed cap)", got)
	}

	// (c) kvBytesPerToken <= 0 falls back to the kvCacheBytesPerToken default
	// (400000): an unreported per-model KV cost must match the explicit default,
	// for both a zero and a negative input.
	explicit := coldTokenBudgetEstimate(64, 12, 400000)
	if got := coldTokenBudgetEstimate(64, 12, 0); got != explicit {
		t.Fatalf("kvpt=0 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	if got := coldTokenBudgetEstimate(64, 12, -1); got != explicit {
		t.Fatalf("kvpt=-1 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	// A reported per-model KV cost is honored (and a cheaper per-token cost
	// yields strictly more tokens), proving the parameter is actually used.
	if got := coldTokenBudgetEstimate(64, 12, 200000); got <= explicit {
		t.Fatalf("cheaper kvpt estimate = %d, want > default-kvpt estimate %d", got, explicit)
	}

	// (d) Unusable inputs → 0 (gate disabled): no total memory, or no model size.
	if got := coldTokenBudgetEstimate(0, 12, 400000); got != 0 {
		t.Fatalf("totalMemoryGB<=0 estimate = %d, want 0", got)
	}
	if got := coldTokenBudgetEstimate(-1, 12, 400000); got != 0 {
		t.Fatalf("totalMemoryGB<0 estimate = %d, want 0", got)
	}
	if got := coldTokenBudgetEstimate(64, 0, 400000); got != 0 {
		t.Fatalf("modelSizeGB<=0 estimate = %d, want 0", got)
	}
	if got := coldTokenBudgetEstimate(64, -1, 400000); got != 0 {
		t.Fatalf("modelSizeGB<0 estimate = %d, want 0", got)
	}
}

// TestSnapshotStructuralBudget pins how a single provider's snapshot maps to a
// structural token budget and whether that budget is known (fail-open) per the
// three branches in snapshotStructuralBudget.
func TestSnapshotStructuralBudget(t *testing.T) {
	// Resident slot with a reported active budget: authoritative and known.
	if budget, known := snapshotStructuralBudget(routingSnapshot{activeTokenBudgetMax: 8192}); !known || budget != 8192 {
		t.Fatalf("resident-with-budget = (%d, %v), want (8192, true)", budget, known)
	}

	// The reported active budget wins even when memory/size data is also present
	// (it must NOT fall through to the cold estimate for a loaded model).
	if budget, known := snapshotStructuralBudget(routingSnapshot{
		activeTokenBudgetMax: 8192,
		modelLoaded:          true,
		totalMemoryGB:        64,
		modelSizeGB:          12,
	}); !known || budget != 8192 {
		t.Fatalf("resident-with-budget+mem = (%d, %v), want (8192, true)", budget, known)
	}

	// Resident but no budget reported (legacy provider): unknown → fail-open.
	if budget, known := snapshotStructuralBudget(routingSnapshot{modelLoaded: true}); known || budget != 0 {
		t.Fatalf("resident-no-budget = (%d, %v), want (0, false)", budget, known)
	}

	// Cold/on-disk with memory + size data: known, using the optimistic cold
	// estimate. Unreported kvBytesPerToken falls back to the 400000 default.
	wantCold := coldTokenBudgetEstimate(64, 12, 0)
	if budget, known := snapshotStructuralBudget(routingSnapshot{totalMemoryGB: 64, modelSizeGB: 12}); !known || budget != wantCold {
		t.Fatalf("cold-fitting = (%d, %v), want (%d, true)", budget, known, wantCold)
	}
	// A cold slot threads its reported per-model KV cost into the estimate.
	wantColdKVPT := coldTokenBudgetEstimate(64, 12, 200000)
	if budget, known := snapshotStructuralBudget(routingSnapshot{
		totalMemoryGB:   64,
		modelSizeGB:     12,
		kvBytesPerToken: 200000,
	}); !known || budget != wantColdKVPT {
		t.Fatalf("cold-fitting+kvpt = (%d, %v), want (%d, true)", budget, known, wantColdKVPT)
	}

	// Cold but missing memory or size data: cannot estimate → unknown.
	if budget, known := snapshotStructuralBudget(routingSnapshot{modelSizeGB: 12}); known || budget != 0 {
		t.Fatalf("cold-missing-memory = (%d, %v), want (0, false)", budget, known)
	}
	if budget, known := snapshotStructuralBudget(routingSnapshot{totalMemoryGB: 64}); known || budget != 0 {
		t.Fatalf("cold-missing-size = (%d, %v), want (0, false)", budget, known)
	}

	// Cold with memory + size data but NO post-load KV headroom (weights ~fill the
	// node): the estimate is 0 yet it is a KNOWN budget, not "unknown" — so the
	// gate can confidently reject rather than fail open.
	if budget, known := snapshotStructuralBudget(routingSnapshot{totalMemoryGB: 16, modelSizeGB: 14}); !known || budget != 0 {
		t.Fatalf("cold-no-headroom = (%d, %v), want (0, true)", budget, known)
	}
}

// TestPredictServableContextTier covers tier 1 (model context window), which is
// provider-agnostic, so it needs no registered providers.
func TestPredictServableContextTier(t *testing.T) {
	reg := New(testLogger())
	model := "ctx-model"

	// prompt 9000 + max 256 = 9256 > contextLimit 8192 → guaranteed-unservable.
	v := reg.PredictServable(model, 9000, 9000, 256, 8192, RequestTraits{}, false)
	if v.Servable {
		t.Fatalf("over-context request reported servable: %+v", v)
	}
	if v.Reason != ServabilityContextExceeded {
		t.Fatalf("reason = %q, want %q", v.Reason, ServabilityContextExceeded)
	}
	if v.RequestTokens != 9256 {
		t.Fatalf("RequestTokens = %d, want 9256 (9000 prompt + 256 max)", v.RequestTokens)
	}
	if v.ContextLimit != 8192 {
		t.Fatalf("ContextLimit = %d, want 8192", v.ContextLimit)
	}

	// prompt 4000 + max 256 = 4256 <= contextLimit 131072 → context tier passes;
	// with an empty fleet the budget tier fails open → servable.
	v = reg.PredictServable(model, 4000, 4000, 256, 131072, RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("within-context request reported unservable (must fail open on empty fleet): %+v", v)
	}
	if v.Reason != "" {
		t.Fatalf("reason = %q, want empty for a servable verdict", v.Reason)
	}
	if v.RequestTokens != 4256 {
		t.Fatalf("RequestTokens = %d, want 4256 (4000 prompt + 256 max)", v.RequestTokens)
	}
}

// TestPredictServableTokenBudgetTier covers tier 2 (fleet token-budget ceiling)
// with eligible, resident providers reporting a known active budget. The fleet
// ceiling is the LARGEST budget across providers.
func TestPredictServableTokenBudgetTier(t *testing.T) {
	reg := New(testLogger())
	model := "budget-tier-model"
	// Two eligible providers with resident ("running") slots and known budgets;
	// the fleet ceiling is the larger of the two (8192).
	makeTokenBudgetProvider(t, reg, "big", model, 100, 0, 8192, 80)
	makeTokenBudgetProvider(t, reg, "small", model, 100, 0, 4096, 80)

	// prompt 20000 + max 256 = 20256 > fleet max 8192, and every provider's
	// budget is known → confident reject as prompt_too_long. contextLimit=0
	// disables tier 1.
	over := reg.PredictServable(model, 20000, 20000, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("over-budget request reported servable: %+v", over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
	}
	if over.RequestTokens != 20256 {
		t.Fatalf("RequestTokens = %d, want 20256", over.RequestTokens)
	}
	if over.FleetMaxBudget != 8192 {
		t.Fatalf("FleetMaxBudget = %d, want 8192 (largest eligible budget)", over.FleetMaxBudget)
	}
	if over.ProviderCount != 2 {
		t.Fatalf("ProviderCount = %d, want 2", over.ProviderCount)
	}

	// prompt 1000 + max 256 = 1256 <= fleet max 8192 → fits → servable.
	within := reg.PredictServable(model, 1000, 1000, 256, 0, RequestTraits{}, false)
	if !within.Servable {
		t.Fatalf("within-budget request reported unservable: %+v", within)
	}
	if within.Reason != "" {
		t.Fatalf("reason = %q, want empty for a servable verdict", within.Reason)
	}
	if within.RequestTokens != 1256 {
		t.Fatalf("RequestTokens = %d, want 1256", within.RequestTokens)
	}
	if within.FleetMaxBudget != 8192 {
		t.Fatalf("FleetMaxBudget = %d, want 8192", within.FleetMaxBudget)
	}
}

// TestPredictServableContextPromptOnlyAffectsContextTier guards the DAR-347
// review fix: the calibrated contextPromptTokens must drive ONLY the context
// tier, never the token-budget tier. The budget tier always uses the RAW
// estimate, so a calibration multiplier can never over-reject a request that fits
// a provider's real KV budget (a false-NO / underutilization).
func TestPredictServableContextPromptOnlyAffectsContextTier(t *testing.T) {
	reg := New(testLogger())
	model := "context-prompt-isolation-model"
	makeTokenBudgetProvider(t, reg, "p", model, 100, 0, 8192, 80) // fleet max budget 8192

	// Budget tier (contextLimit=0 disables tier 1): raw 4000+256=4256 <= 8192
	// fits. A calibrated context-prompt of 9000 (9256 > 8192) must NOT leak into
	// the budget tier and shed it.
	budget := reg.PredictServable(model, 4000, 9000, 256, 0, RequestTraits{}, false)
	if !budget.Servable {
		t.Fatalf("calibrated context prompt leaked into the budget tier and over-rejected a budget-fitting request: %+v", budget)
	}
	if budget.RequestTokens != 4256 {
		t.Fatalf("RequestTokens = %d, want 4256 (budget tier must use the RAW estimate)", budget.RequestTokens)
	}

	// Context tier: raw 4000+256=4256 fits an 8192 context, but the calibrated
	// 9000+256=9256 exceeds it — the context tier DOES use the calibrated prompt.
	ctx := reg.PredictServable(model, 4000, 9000, 256, 8192, RequestTraits{}, false)
	if ctx.Servable || ctx.Reason != ServabilityContextExceeded {
		t.Fatalf("context tier did not use the calibrated context prompt: %+v", ctx)
	}
	if ctx.RequestTokens != 9256 {
		t.Fatalf("RequestTokens = %d, want 9256 (context tier uses the calibrated prompt)", ctx.RequestTokens)
	}
}

// TestPredictServableFailsOpenOnUnknownBudget proves the fail-open invariant:
// if ANY eligible provider's budget is unknown, the budget tier is skipped even
// for an enormous request — because that provider's true budget might hold it.
func TestPredictServableFailsOpenOnUnknownBudget(t *testing.T) {
	reg := New(testLogger())
	model := "fail-open-model"
	// One resident provider with NO reported active budget (legacy → unknown)...
	makeSchedulerProvider(t, reg, "legacy", model, 100)
	// ...alongside one with a small KNOWN budget. The unknown provider must
	// force fail-open regardless of the known ceiling.
	makeTokenBudgetProvider(t, reg, "known-small", model, 100, 0, 4096, 80)

	huge := reg.PredictServable(model, 1_000_000, 1_000_000, 256, 0, RequestTraits{}, false)
	if !huge.Servable {
		t.Fatalf("request must fail open when an eligible provider's budget is unknown: %+v", huge)
	}
	if huge.Reason != "" {
		t.Fatalf("reason = %q, want empty (fail open)", huge.Reason)
	}
	if huge.ProviderCount != 2 {
		t.Fatalf("ProviderCount = %d, want 2", huge.ProviderCount)
	}
}

// TestPredictServableKnownZeroColdBudgetUnservable proves the fail-open guard is
// keyed on UNKNOWN budgets, not on a zero ceiling: a fleet whose only eligible
// provider is a cold node with no post-load KV headroom (a KNOWN budget of 0) is
// rejected as prompt_too_long. Otherwise the request would be admitted into a
// guaranteed provider-side token/KV rejection.
func TestPredictServableKnownZeroColdBudgetUnservable(t *testing.T) {
	reg := New(testLogger())
	model := "zero-budget-model"
	// 14 GB weights (padded ~15.6 GiB) + the activation reserve exceed 90% of a
	// 16 GB node, so coldTokenBudgetEstimate is 0 (a known zero). MinRAMGB 14 <= 16
	// keeps it past the hardware-fit gate (counted, not model_too_large).
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 14, MinRAMGB: 14}})
	makeWarmPoolColdProvider(t, reg, "tight", model, 80, 16, 0)

	v := reg.PredictServable(model, 1000, 1000, 256, 0, RequestTraits{}, false)
	if v.Servable {
		t.Fatalf("known-zero-budget fleet reported servable (must reject, not fail open): %+v", v)
	}
	if v.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", v.Reason, ServabilityPromptTooLong)
	}
	if v.ProviderCount != 1 {
		t.Fatalf("ProviderCount = %d, want 1 (cold node fits hardware, counted)", v.ProviderCount)
	}
	if v.FleetMaxBudget != 0 {
		t.Fatalf("FleetMaxBudget = %d, want 0 (known-zero cold budget)", v.FleetMaxBudget)
	}
}

// TestPredictServableEmptyFleet proves an empty fleet is fail-open: zero
// eligible providers is a different rejection path, never prompt_too_long.
func TestPredictServableEmptyFleet(t *testing.T) {
	reg := New(testLogger())

	v := reg.PredictServable("no-such-model", 10_000_000, 10_000_000, 256, 0, RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("empty fleet must be servable (fail open): %+v", v)
	}
	if v.Reason != "" {
		t.Fatalf("reason = %q, want empty", v.Reason)
	}
	if v.ProviderCount != 0 {
		t.Fatalf("ProviderCount = %d, want 0", v.ProviderCount)
	}
	if v.FleetMaxBudget != 0 {
		t.Fatalf("FleetMaxBudget = %d, want 0", v.FleetMaxBudget)
	}
}
