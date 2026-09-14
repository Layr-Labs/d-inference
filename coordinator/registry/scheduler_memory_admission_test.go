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
	got := resolveEffectiveTPS(snapPtr(snap))
	want := effectiveDecodeTPS(100, 2)
	if got != want {
		t.Fatalf("resolveEffectiveTPS()=%f, want %f (formula fallback)", got, want)
	}

	// When observedDecodeTPS is set, should use it directly.
	snap.observedDecodeTPS = 55.5
	got = resolveEffectiveTPS(snapPtr(snap))
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

// The cold-load *planner* (modelLoadCandidatePendingLocked, used by warm-pool /
// queue-before-shed) must also respect free_for_load_gb, so it never sends a
// load_model the direct gate would reject (Codex #390 P2). Mirrors the direct path.
func TestModelLoadCandidateRespectsFreeForLoad(t *testing.T) {
	reg := New(testLogger())
	const model = "free-for-load-planner"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 14}})

	p := registerProviderWithModel(reg, "p1", model)
	makeProviderRoutable(p)
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
