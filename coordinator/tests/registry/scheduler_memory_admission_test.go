package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Providers whose slots report no token budget rank by decode throughput.
func TestBudgetlessProvidersRankByDecodeTPS(t *testing.T) {
	reg := production.New(testLogger())
	model := "budgetless-routing-model"

	// Two providers with no token budget fields.
	p1 := makeSchedulerProvider(t, reg, "fast", model, 120)
	p2 := makeSchedulerProvider(t, reg, "slow", model, 40)
	_ = p1
	_ = p2

	req := &production.PendingRequest{
		RequestID:             "req-budgetless",
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
		t.Fatalf("selected %q, want 'fast' (higher decode TPS without budgets)", selected.ID)
	}
}

func TestResolveEffectiveTPSFallback(t *testing.T) {
	// When observedDecodeTPS is 0, should fall back to formula-based TPS.
	rates := performance.Rates{
		StaticDecode:   100,
		ObservedBatch:  2,
		Occupancy:      2,
		ObservedDecode: 0,
	}
	got := rates.EffectiveDecode(warmplan.DecodeLoadFactor)
	want := performance.EffectiveDecode(100, 2, warmplan.DecodeLoadFactor)
	if got != want {
		t.Fatalf("resolveEffectiveTPS()=%f, want %f (formula fallback)", got, want)
	}

	// When observedDecodeTPS is set, should use it directly.
	rates.ObservedDecode = 55.5
	got = rates.EffectiveDecode(warmplan.DecodeLoadFactor)
	if got != 55.5 {
		t.Fatalf("resolveEffectiveTPS()=%f, want 55.5 (observed)", got)
	}
}

func TestResolvedModelTPSLockedUsesMatchingObservedSlot(t *testing.T) {
	reg := production.New(testLogger())
	model := "observed-model-tps"
	p := makeSchedulerProvider(t, reg, "observed", model, 23)
	p.Mu().Lock()
	p.PrefillTPS = 700
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:              "other-model",
		ObservedDecodeTPS:  999,
		ObservedPrefillTPS: 9999,
	})
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 0
	staticDecode := quality.DecodeFallback(p.DecodeTPS, p.Hardware)
	staticPrefill := quality.PrefillFallback(p.PrefillTPS, staticDecode, production.PrefillToDecodeRatio())
	decodeTPS, prefillTPS := quality.ModelRates(model, p.BackendCapacity, staticDecode, staticPrefill)
	p.Mu().Unlock()

	if decodeTPS != 73 {
		t.Fatalf("decodeTPS = %v, want matching observed decode 73", decodeTPS)
	}
	if prefillTPS != 700 {
		t.Fatalf("prefillTPS = %v, want static prefill fallback 700", prefillTPS)
	}
}

func TestResolvedModelTPSLockedIgnoresOtherModelObservedSlot(t *testing.T) {
	reg := production.New(testLogger())
	model := "static-model-tps"
	p := makeSchedulerProvider(t, reg, "static", model, 23)
	p.Mu().Lock()
	p.PrefillTPS = 700
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 0
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 0
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:              "other-model",
		ObservedDecodeTPS:  999,
		ObservedPrefillTPS: 9999,
	})
	staticDecode := quality.DecodeFallback(p.DecodeTPS, p.Hardware)
	staticPrefill := quality.PrefillFallback(p.PrefillTPS, staticDecode, production.PrefillToDecodeRatio())
	decodeTPS, prefillTPS := quality.ModelRates(model, p.BackendCapacity, staticDecode, staticPrefill)
	p.Mu().Unlock()

	if decodeTPS != 23 {
		t.Fatalf("decodeTPS = %v, want static decode fallback 23", decodeTPS)
	}
	if prefillTPS != 700 {
		t.Fatalf("prefillTPS = %v, want static prefill fallback 700", prefillTPS)
	}
}

func TestSlotHeadroomWithExhaustedTokenBudgetRejectsCapacity(t *testing.T) {
	reg := production.New(testLogger())
	model := "budget-headroom-model"
	p := makeTokenBudgetProvider(t, reg, "budget-headroom", model, 100, 32_000, 32_768, 80)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.Mu().Unlock()

	selected, decision := reg.ReserveProviderEx(model, &production.PendingRequest{
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
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 256, 1024, production.RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestIdleResidentAdmittedByFallbackMemoryGate(t *testing.T) {
	reg := production.New(testLogger())
	model := "idle-resident-fallback"
	reg.SetModelCatalog([]production.CatalogEntry{{ID: model, SizeGB: 40}})
	p := makeSchedulerProvider(t, reg, "idle-resident", model, 100)
	p.Mu().Lock()
	p.BackendCapacity.GPUMemoryActiveGB = 42
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle"
	// Force legacy memory admission path; active token budget path would bypass
	// the bug this test guards.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 0
	p.Mu().Unlock()

	selected, decision := reg.ReserveProviderEx(model, &production.PendingRequest{RequestID: "idle-resident", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if selected == nil {
		t.Fatalf("idle resident provider rejected; decision=%+v", decision)
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}

func TestFreeMemoryAdmitsFallsBackWithoutBudget(t *testing.T) {
	// Without token budget (max=0), should fall back to memory-based check.
	snap := memorypolicy.Input{
		ActiveTokenBudgetUsed: 0,
		ActiveTokenBudgetMax:  0,
		ModelSizeGB:           8,
		TotalMemoryGB:         64,
		GPUMemoryActiveGB:     10,
		ModelLoaded:           true,
	}
	// Model already loaded, so only KV matters. Lots of free memory.
	if !memorypolicy.Admits(memoryInputPtr(snap), 100, 256) {
		t.Fatal("should admit with plenty of free memory in legacy mode")
	}
}

// When the provider reports freeForLoadGB, the cold-load gate uses it as the
// single source of truth: admit iff the model's weights fit, regardless of the
// coarse total-memory heuristic.
func TestFreeMemoryAdmitsColdLoadUsesReportedFreeForLoad(t *testing.T) {
	freeForLoad := 9.0 // e.g. a 24GB box reports ~9GB loadable
	base := memorypolicy.Input{
		TotalMemoryGB:   64, // heuristic would happily admit; reported value must win
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   &freeForLoad,
	}

	fits := base
	fits.ModelSizeGB = 8 // 8 <= 9 → admit
	if !memorypolicy.Admits(memoryInputPtr(fits), 100, 256) {
		t.Fatal("8GB model must be admitted: fits in reported 9GB free-for-load")
	}

	tooBig := base
	tooBig.ModelSizeGB = 14 // 14 > 9 → reject, even though heuristic on 64GB would admit
	if memorypolicy.Admits(memoryInputPtr(tooBig), 100, 256) {
		t.Fatal("14GB model must be rejected: exceeds reported 9GB free-for-load")
	}
}

// A reported 0 ("can't load anything now") must reject any cold load, not fall
// back to the heuristic (nil is the only fallback trigger).
func TestFreeMemoryAdmitsColdLoadReportedZeroRejects(t *testing.T) {
	zero := 0.0
	snap := memorypolicy.Input{
		ModelSizeGB:     4,
		TotalMemoryGB:   64,
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   &zero,
	}
	if memorypolicy.Admits(memoryInputPtr(snap), 100, 256) {
		t.Fatal("reported free-for-load 0 must reject a cold load")
	}
}

// The cold-load gate must compare against the provider's PADDED-GiB load basis,
// not the raw catalog size, or a near-threshold model whose raw size fits but
// whose padded estimate doesn't gets routed and then 503'd at load (Codex #390).
func TestFreeMemoryAdmitsColdLoadNormalizesCatalogSize(t *testing.T) {
	free := 10.0
	// Raw 9.5GB naively "fits" 10, but padded 9.5*1.1176≈10.6 > 10 → must reject.
	snap := memorypolicy.Input{
		ModelSizeGB:     9.5,
		TotalMemoryGB:   64,
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   &free,
	}
	if memorypolicy.Admits(memoryInputPtr(snap), 100, 256) {
		t.Fatal("near-threshold model must reject: padded estimate exceeds reported free-for-load")
	}
	snap.ModelSizeGB = 8 // padded 8*1.1176≈8.94 <= 10 → admit
	if !memorypolicy.Admits(memoryInputPtr(snap), 100, 256) {
		t.Fatal("8GB model must admit: padded estimate fits reported free-for-load")
	}
}

// Legacy provider (freeForLoadGB nil) falls back to the total-memory heuristic.
func TestFreeMemoryAdmitsColdLoadFallsBackWhenUnreported(t *testing.T) {
	snap := memorypolicy.Input{
		ModelSizeGB:     16,
		TotalMemoryGB:   64, // 16 + ~0 + 4 = 20 <= 64 → admit via heuristic
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   nil,
	}
	if !memorypolicy.Admits(memoryInputPtr(snap), 100, 256) {
		t.Fatal("legacy provider must fall back to the total-memory heuristic (admit)")
	}
}

// The cold-load planner must also respect free_for_load_gb, so it never plans a
// load_model the direct gate would reject (Codex #390 P2). Mirrors the direct path.
func TestModelLoadCandidateRespectsFreeForLoad(t *testing.T) {
	var planner *production.ModelLoadPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		ModelLoadPlanning: func(p *production.ModelLoadPlanner) production.ModelLoadPlanning {
			planner = p
			return p
		},
	})
	const model = "free-for-load-planner"
	reg.SetModelCatalog([]production.CatalogEntry{{ID: model, SizeGB: 14}})

	p := registerProviderWithModel(reg, "p1", model)
	makeProviderRoutable(p)
	p.Mu().Lock()
	p.Hardware.MemoryGB = 64 // passes the static hardware gate
	p.Mu().Unlock()
	now := time.Now()
	preparation := planner.Prepare()
	defer preparation.Close()

	setFFL := func(v *float64) {
		p.Mu().Lock()
		p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, FreeForLoadGB: v}
		p.Mu().Unlock()
	}

	low := 9.0
	setFFL(&low)
	if _, ok := preparation.Candidate(p.ID, model, now); ok {
		t.Fatal("planner must reject a 14GB model when the provider reports 9GB free-for-load")
	}

	high := 20.0
	setFFL(&high)
	if _, ok := preparation.Candidate(p.ID, model, now); !ok {
		t.Fatal("planner must accept a 14GB model when the provider reports 20GB free-for-load")
	}

	setFFL(nil) // legacy provider: fall back to the static hardware gate (64GB box)
	if _, ok := preparation.Candidate(p.ID, model, now); !ok {
		t.Fatal("legacy provider (no free-for-load) must fall back to the static hardware gate")
	}
}
