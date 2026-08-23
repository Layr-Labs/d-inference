package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestLegacyProviderFallsBackToOldRouting(t *testing.T) {
	reg := New(testLogger())
	model := "legacy-routing-model"

	// Two legacy providers (no token budget fields) — should use old cost function.
	p1 := makeSchedulerProvider(t, reg, "fast", model, 120)
	p2 := makeSchedulerProvider(t, reg, "slow", model, 40)
	_ = p1
	_ = p2

	req := &PendingRequest{
		RequestID:             "req-legacy",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	// Faster decode TPS should win when both idle with no budget reporting.
	if selected.ID != "fast" {
		t.Fatalf("selected %q, want 'fast' (higher decode TPS in legacy mode)", selected.ID)
	}
}

func TestResolveEffectiveTPSFallback(t *testing.T) {
	// When observedDecodeTPS is 0, should fall back to formula-based TPS.
	snap := routingSnapshot{
		decodeTPS:         100,
		backendRunning:    2,
		observedDecodeTPS: 0,
	}
	got := resolveEffectiveTPS(snap)
	want := effectiveDecodeTPS(100, 2)
	if got != want {
		t.Fatalf("resolveEffectiveTPS()=%f, want %f (formula fallback)", got, want)
	}

	// When observedDecodeTPS is set, should use it directly.
	snap.observedDecodeTPS = 55.5
	got = resolveEffectiveTPS(snap)
	if got != 55.5 {
		t.Fatalf("resolveEffectiveTPS()=%f, want 55.5 (observed)", got)
	}
}

func TestResolvedModelTPSLockedUsesMatchingObservedSlot(t *testing.T) {
	reg := New(testLogger())
	model := "observed-model-tps"
	p := makeSchedulerProvider(t, reg, "observed", model, 23)
	p.mu.Lock()
	p.PrefillTPS = 700
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:              "other-model",
		ObservedDecodeTPS:  999,
		ObservedPrefillTPS: 9999,
	})
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 0
	decodeTPS, prefillTPS := resolvedModelTPSLocked(p, model)
	p.mu.Unlock()

	if decodeTPS != 73 {
		t.Fatalf("decodeTPS = %v, want matching observed decode 73", decodeTPS)
	}
	if prefillTPS != 700 {
		t.Fatalf("prefillTPS = %v, want static prefill fallback 700", prefillTPS)
	}
}

func TestResolvedModelTPSLockedIgnoresOtherModelObservedSlot(t *testing.T) {
	reg := New(testLogger())
	model := "static-model-tps"
	p := makeSchedulerProvider(t, reg, "static", model, 23)
	p.mu.Lock()
	p.PrefillTPS = 700
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 0
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 0
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:              "other-model",
		ObservedDecodeTPS:  999,
		ObservedPrefillTPS: 9999,
	})
	decodeTPS, prefillTPS := resolvedModelTPSLocked(p, model)
	p.mu.Unlock()

	if decodeTPS != 23 {
		t.Fatalf("decodeTPS = %v, want static decode fallback 23", decodeTPS)
	}
	if prefillTPS != 700 {
		t.Fatalf("prefillTPS = %v, want static prefill fallback 700", prefillTPS)
	}
}

func TestFreeMemoryAdmitsTokenBudget(t *testing.T) {
	// With token budget, should use budget-based admission.
	snap := routingSnapshot{
		activeTokenBudgetUsed: 28_000,
		activeTokenBudgetMax:  32_768,
		modelSizeGB:           8,
		totalMemoryGB:         64,
	}
	// Request for 500 + 4096 = 4596 tokens. 28000 + 4596 = 32596 <= 32768. Fits.
	if !freeMemoryAdmits(snap, 500, 4096) {
		t.Fatal("should admit: 28000 + 4596 = 32596 <= 32768")
	}
	// Request for 500 + 4500 = 5000 tokens. 28000 + 5000 = 33000 > 32768. Rejected.
	if freeMemoryAdmits(snap, 500, 4500) {
		t.Fatal("should reject: 28000 + 5000 = 33000 > 32768")
	}
}

func TestFreeMemoryAdmitsIncludesQueuedBudget(t *testing.T) {
	snap := routingSnapshot{
		activeTokenBudgetUsed: 20_000,
		activeTokenBudgetMax:  32_768,
		queuedTokenBudget:     10_000,
		modelSizeGB:           8,
		totalMemoryGB:         64,
	}
	// active(20K) + queued(10K) + request(500+4096=4596) = 34596 > 32768. Rejected.
	if freeMemoryAdmits(snap, 500, 4096) {
		t.Fatal("should reject: active + queued + request exceeds budget")
	}
	// Without queued budget: active(20K) + request(4596) = 24596 <= 32768. Fits.
	snap.queuedTokenBudget = 0
	if !freeMemoryAdmits(snap, 500, 4096) {
		t.Fatal("should admit when queued budget is zero")
	}
}

func TestFreeMemoryAdmitsFallsBackWithoutBudget(t *testing.T) {
	// Without token budget (max=0), should fall back to memory-based check.
	snap := routingSnapshot{
		activeTokenBudgetUsed: 0,
		activeTokenBudgetMax:  0,
		modelSizeGB:           8,
		totalMemoryGB:         64,
		gpuMemoryActiveGB:     10,
		modelLoaded:           true,
	}
	// Model already loaded, so only KV matters. Lots of free memory.
	if !freeMemoryAdmits(snap, 100, 256) {
		t.Fatal("should admit with plenty of free memory in legacy mode")
	}
}

// When the provider reports freeForLoadGB, the cold-load gate uses it as the
// single source of truth: admit iff the model's weights fit, regardless of the
// coarse total-memory heuristic.
func TestFreeMemoryAdmitsColdLoadUsesReportedFreeForLoad(t *testing.T) {
	freeForLoad := 9.0 // e.g. a 24GB box reports ~9GB loadable
	base := routingSnapshot{
		totalMemoryGB:   64, // heuristic would happily admit; reported value must win
		availableOnDisk: true,
		modelLoaded:     false,
		totalPending:    0,
		freeForLoadGB:   &freeForLoad,
	}

	fits := base
	fits.modelSizeGB = 8 // 8 <= 9 → admit
	if !freeMemoryAdmits(fits, 100, 256) {
		t.Fatal("8GB model must be admitted: fits in reported 9GB free-for-load")
	}

	tooBig := base
	tooBig.modelSizeGB = 14 // 14 > 9 → reject, even though heuristic on 64GB would admit
	if freeMemoryAdmits(tooBig, 100, 256) {
		t.Fatal("14GB model must be rejected: exceeds reported 9GB free-for-load")
	}
}

// A reported 0 ("can't load anything now") must reject any cold load, not fall
// back to the heuristic (nil is the only fallback trigger).
func TestFreeMemoryAdmitsColdLoadReportedZeroRejects(t *testing.T) {
	zero := 0.0
	snap := routingSnapshot{
		modelSizeGB:     4,
		totalMemoryGB:   64,
		availableOnDisk: true,
		modelLoaded:     false,
		totalPending:    0,
		freeForLoadGB:   &zero,
	}
	if freeMemoryAdmits(snap, 100, 256) {
		t.Fatal("reported free-for-load 0 must reject a cold load")
	}
}

// The cold-load gate must compare against the provider's PADDED-GiB load basis,
// not the raw catalog size, or a near-threshold model whose raw size fits but
// whose padded estimate doesn't gets routed and then 503'd at load (Codex #390).
func TestFreeMemoryAdmitsColdLoadNormalizesCatalogSize(t *testing.T) {
	free := 10.0
	// Raw 9.5GB naively "fits" 10, but padded 9.5*1.1176≈10.6 > 10 → must reject.
	snap := routingSnapshot{
		modelSizeGB:     9.5,
		totalMemoryGB:   64,
		availableOnDisk: true,
		modelLoaded:     false,
		totalPending:    0,
		freeForLoadGB:   &free,
	}
	if freeMemoryAdmits(snap, 100, 256) {
		t.Fatal("near-threshold model must reject: padded estimate exceeds reported free-for-load")
	}
	snap.modelSizeGB = 8 // padded 8*1.1176≈8.94 <= 10 → admit
	if !freeMemoryAdmits(snap, 100, 256) {
		t.Fatal("8GB model must admit: padded estimate fits reported free-for-load")
	}
}

// The cold-load *planner* (modelLoadCandidatePendingLocked, used by warm-pool /
// queue-before-shed) must also respect free_for_load_gb, so it never sends a
// load_model the direct gate would reject (Codex #390 P2). Mirrors the direct path.
func TestModelLoadCandidateRespectsFreeForLoad(t *testing.T) {
	reg := New(testLogger())
	const model = "free-for-load-planner"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 14}})

	p := registerProviderWithModel(reg, "p1", model)
	testMakeTextRoutable(p)
	p.mu.Lock()
	p.Hardware.MemoryGB = 64 // passes the static hardware gate
	p.mu.Unlock()
	now := time.Now()

	setFFL := func(v *float64) {
		p.mu.Lock()
		p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, FreeForLoadGB: v}
		p.mu.Unlock()
	}

	low := 9.0
	setFFL(&low)
	if _, ok := reg.modelLoadCandidatePendingLocked(p, model, now); ok {
		t.Fatal("planner must reject a 14GB model when the provider reports 9GB free-for-load")
	}

	high := 20.0
	setFFL(&high)
	if _, ok := reg.modelLoadCandidatePendingLocked(p, model, now); !ok {
		t.Fatal("planner must accept a 14GB model when the provider reports 20GB free-for-load")
	}

	setFFL(nil) // legacy provider → fall back to the static hardware gate (64GB box)
	if _, ok := reg.modelLoadCandidatePendingLocked(p, model, now); !ok {
		t.Fatal("legacy provider (no free-for-load) must fall back to the static hardware gate")
	}
}

// Legacy provider (freeForLoadGB nil) falls back to the total-memory heuristic.
func TestFreeMemoryAdmitsColdLoadFallsBackWhenUnreported(t *testing.T) {
	snap := routingSnapshot{
		modelSizeGB:     16,
		totalMemoryGB:   64, // 16 + ~0 + 4 = 20 <= 64 → admit via heuristic
		availableOnDisk: true,
		modelLoaded:     false,
		totalPending:    0,
		freeForLoadGB:   nil,
	}
	if !freeMemoryAdmits(snap, 100, 256) {
		t.Fatal("legacy provider must fall back to the total-memory heuristic (admit)")
	}
}

func TestSlotHeadroomWithExhaustedTokenBudgetRejectsCapacity(t *testing.T) {
	reg := New(testLogger())
	model := "budget-headroom-model"
	p := makeTokenBudgetProvider(t, reg, "budget-headroom", model, 100, 32_000, 32_768, 80)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:             "req-budget-reject",
		Model:                 model,
		EstimatedPromptTokens: 256,
		RequestedMaxTokens:    1024,
	})
	if selected != nil {
		t.Fatalf("selected %q, want nil with exhausted token budget", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection from token budget", decision)
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 256, 1024, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestIdleResidentAdmittedByFallbackMemoryGate(t *testing.T) {
	reg := New(testLogger())
	model := "idle-resident-fallback"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 40}})
	p := makeSchedulerProvider(t, reg, "idle-resident", model, 100)
	p.mu.Lock()
	p.BackendCapacity.GPUMemoryActiveGB = 42
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle"
	// Force legacy memory admission path; active token budget path would bypass
	// the bug this test guards.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 0
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "idle-resident", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if selected == nil {
		t.Fatalf("idle resident provider rejected; decision=%+v", decision)
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}

// A cold provider below the catalog's weight requirement is never admitted.
func TestColdModelRejectsProviderBelowCatalogSize(t *testing.T) {
	reg := New(testLogger())
	model := "needs-32gb-model"
	// Catalog says this model needs ~32 GB.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 32}})

	// One small (24 GB) provider claiming to serve the model but not
	// currently running it (cold backend). With no memory gate, this
	// provider would be selected and then OOM trying to load the model.
	schedulerScenarioProvider{id: "small", decodeTPS: 30, totalMemGB: 24, gpuActiveGB: 1,
		slotState: "idle_shutdown"}.register(t, reg, model)

	p := reserveSchedulerScenario(reg, model, 256)
	if p != nil {
		t.Fatalf("24 GB provider selected for a 32 GB cold model: %q", p.ID)
	}
}

// Memory fit outranks idle state when only the busy provider can load the model.
func TestBusyFittingProviderBeatsIdleUnfitProvider(t *testing.T) {
	reg := New(testLogger())
	model := "p1-busy-vs-idle-model"
	// 32 GB model: only the 128 GB provider fits.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 32}})

	schedulerScenarioProvider{id: "big-busy", decodeTPS: 80, totalMemGB: 128, gpuActiveGB: 50,
		pending: 1, backendRun: 1}.register(t, reg, model)
	// Small provider has the model in its catalog but no slot loaded,
	// so the gate must compute weights + KV against free memory.
	schedulerScenarioProvider{id: "small-idle", decodeTPS: 20, totalMemGB: 24, gpuActiveGB: 1,
		slotState: "idle_shutdown"}.register(t, reg, model)

	p := reserveSchedulerScenario(reg, model, 256)
	if p == nil {
		t.Fatal("expected the busy big provider to win, got nil")
	}
	if p.ID != "big-busy" {
		t.Fatalf("got %q, want the only provider that fits the model", p.ID)
	}
}

// Resident weights are not charged again by cold-load admission.
func TestWarmProviderBypassesColdWeightHeadroom(t *testing.T) {
	reg := New(testLogger())
	model := "p1-warm-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 32}})

	// 48 GB provider currently running the model with 35 GB of GPU
	// memory active (model + some KV). Free memory is 13 GB — far less
	// than the 32 GB model footprint. But the gate must accept this
	// provider because the weights are already resident.
	schedulerScenarioProvider{id: "warm-running", decodeTPS: 60, totalMemGB: 48, gpuActiveGB: 35,
		slotState: "running"}.register(t, reg, model)

	p := reserveSchedulerScenario(reg, model, 256)
	if p == nil {
		t.Fatal("expected warm-running to be admitted (model already loaded), got nil")
	}
	if p.ID != "warm-running" {
		t.Fatalf("got %q, want warm-running", p.ID)
	}
}

// Missing catalog size preserves mixed-version fail-open admission.
func TestUnsizedCatalogEntryFailsOpenMemoryAdmission(t *testing.T) {
	reg := New(testLogger())
	model := "p1-unsized-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}}) // SizeGB unset

	// Tiny provider that would fail the gate if SizeGB were set.
	schedulerScenarioProvider{id: "tiny", decodeTPS: 20, totalMemGB: 8, gpuActiveGB: 7,
		slotState: "idle_shutdown"}.register(t, reg, model)

	p := reserveSchedulerScenario(reg, model, 256)
	if p == nil {
		t.Fatal("expected tiny to be admitted (gate disabled when SizeGB=0), got nil")
	}
}
