package registry

import "testing"

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

// TestPredictServableMixedVersionFleetStagedRollout is the staged-rollout
// regression for the v0.8.0 activation-reserve raise: while the fleet is
// mixed, a COLD pre-0.8.0 provider still holds the old 3 GiB reserve, so its
// cold estimate must be charged 3 GiB — not the new global 5.5. A request
// sized BETWEEN the two estimates (fits the legacy box, not the upgraded one)
// must stay servable as long as any legacy box is eligible; once the whole
// fleet is ≥0.8.0 the same request is confidently shed as prompt_too_long.
func TestPredictServableMixedVersionFleetStagedRollout(t *testing.T) {
	const model = "rollout-model"
	// 64 GB boxes, 12 GB weights, default 400000 B/token:
	//   legacy (3 GiB reserve)  cold budget = 110565 tokens
	//   v0.8.0 (5.5 GiB reserve) cold budget = 103854 tokens
	// Request 105000 + 256 = 105256 sits strictly between the two.
	legacyBudget := coldTokenBudgetEstimate(64, 12, 0, "0.7.12", "")
	newBudget := coldTokenBudgetEstimate(64, 12, 0, "0.8.0", "")
	const reqPrompt, reqMax = 105000, 256
	if int64(reqPrompt+reqMax) <= newBudget || int64(reqPrompt+reqMax) > legacyBudget {
		t.Fatalf("fixture broke: request %d must sit between new budget %d and legacy budget %d",
			reqPrompt+reqMax, newBudget, legacyBudget)
	}

	setVersion := func(p *Provider, v string) {
		p.mu.Lock()
		p.Version = v
		p.mu.Unlock()
	}

	// Mixed fleet: one upgraded box, one legacy box, both COLD.
	mixed := New(testLogger())
	mixed.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 12, MinRAMGB: 12}})
	setVersion(makeWarmPoolColdProvider(t, mixed, "upgraded", model, 80, 64, 0), "0.8.0")
	setVersion(makeWarmPoolColdProvider(t, mixed, "legacy", model, 80, 64, 0), "0.7.12")

	v := mixed.PredictServable(model, reqPrompt, reqPrompt, reqMax, 0, RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("mixed fleet falsely shed a request the legacy box can serve: %+v", v)
	}
	if v.FleetMaxBudget != legacyBudget {
		t.Fatalf("FleetMaxBudget = %d, want the legacy box's %d", v.FleetMaxBudget, legacyBudget)
	}
	if v.ProviderCount != 2 {
		t.Fatalf("ProviderCount = %d, want 2", v.ProviderCount)
	}

	// Fully upgraded fleet: the same request now exceeds every ceiling and is
	// confidently shed — the provider genuinely no longer has that KV room.
	upgraded := New(testLogger())
	upgraded.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 12, MinRAMGB: 12}})
	setVersion(makeWarmPoolColdProvider(t, upgraded, "a", model, 80, 64, 0), "0.8.0")
	setVersion(makeWarmPoolColdProvider(t, upgraded, "b", model, 80, 64, 0), "0.8.1")

	shed := upgraded.PredictServable(model, reqPrompt, reqPrompt, reqMax, 0, RequestTraits{}, false)
	if shed.Servable {
		t.Fatalf("fully-upgraded fleet must shed the between-sized request: %+v", shed)
	}
	if shed.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", shed.Reason, ServabilityPromptTooLong)
	}
	if shed.FleetMaxBudget != newBudget {
		t.Fatalf("FleetMaxBudget = %d, want %d", shed.FleetMaxBudget, newBudget)
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
