package registry_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestQualityCapUsesStaticNotObservedTPS is the regression that matters: a slow
// model's box is capped from its STATIC single-stream rate (~23 tok/s → quality
// batch 1 → cap 2 = ceil(1 × 1.2) at the default overcommit), and the collapsed
// observed-under-load EWMA (~2.6 tok/s, which would force a cap of 1) must NOT
// change the result — otherwise the cap inherits the very feedback loop it
// exists to break.
func TestQualityCapUsesStaticNotObservedTPS(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "")
	p := qualityProvider(t, reg, "gemma-box", gemmaBuild, 23) // static 23 tok/s
	budgetSlot(p, 2.6)                                        // collapsed observed EWMA

	if got := effCap(reg, p, gemmaBuild); got != 2 {
		t.Fatalf("effective cap = %d, want 2 (quality batch 1 from STATIC 23 tok/s × default overcommit, ignoring observed 2.6)", got)
	}
}

// TestQualityCapScalesWithModelSpeed shows the cap is universal and self-tuning:
// a fast model (57 tok/s) keeps a high cap — an order above normal load — that
// never bites, while a slow model (23 tok/s, quality batch 1 at any measured k)
// is tightened to 2. The fast side is k-derived: it is 12 at k = 0.27 and 9 at
// the CBv2-re-fit 0.39, and neither number is the point.
func TestQualityCapScalesWithModelSpeed(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "")

	slow := qualityProvider(t, reg, "slow", gemmaBuild, 23)
	budgetSlot(slow, 0)
	fast := qualityProvider(t, reg, "fast", qwenBuild, 57)
	budgetSlot(fast, 0)

	if got := effCap(reg, slow, gemmaBuild); got != 2 {
		t.Fatalf("slow cap = %d, want 2", got)
	}
	wantFast := wantQualityCap(57, 15, 24, defaultQualityCapOvercommit)
	if got := effCap(reg, fast, qwenBuild); got != wantFast {
		t.Fatalf("fast cap = %d, want %d (ceil(quality batch × 1.2) at k=%.2f, ≤ flat 24) — far above normal load, no regression", got, wantFast, effectiveTPSLoadFactor)
	}
	if wantFast <= 4 {
		t.Fatalf("fast cap %d collapsed to slow-model territory at k=%.2f — a 57 tok/s model must keep real headroom", wantFast, effectiveTPSLoadFactor)
	}
}

// TestQualityCapFallbackRateOnlyCapsDedicated guards the P1 regression: when a
// provider has NOT reported a real decode benchmark (DecodeTPS==0), resolvedDecodeTPS
// falls back to sqrt(memory_bandwidth) — a model-agnostic hardware proxy that
// under-estimates fast models. The cap must therefore bite only DEDICATED models
// from that fallback; a non-dedicated model keeps the flat cap (so healthy
// fast-model traffic isn't shed on a bad rate estimate).
func TestQualityCapFallbackRateOnlyCapsDedicated(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	enableQualityCap(t, reg, "")

	// No DecodeTPS benchmark; rate comes from sqrt(bandwidth)=sqrt(800)≈28.
	mkFallback := func(id, model string) *production.Provider {
		p := qualityProvider(t, reg, id, model, 0) // DecodeTPS unset
		p.Mu().Lock()
		p.Hardware.MemoryBandwidthGBs = 800
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
		p.Mu().Unlock()
		return p
	}

	// Non-dedicated on the fallback rate → NOT capped (flat 24): don't shed a fast
	// model on a hardware proxy that can't see its true ~57 tok/s rate.
	nonDed := mkFallback("qwen-box", qwenBuild)
	if got := effCap(reg, nonDed, qwenBuild); got != 24 {
		t.Fatalf("non-dedicated fallback-rate cap = %d, want 24 (no benchmark → not capped from sqrt(bw))", got)
	}

	// Dedicated on the same fallback rate → capped (best-effort): qc from ~28 tok/s.
	ded := mkFallback("gemma-box", gemmaBuild)
	if got := effCap(reg, ded, gemmaBuild); got >= 24 || got < 1 {
		t.Fatalf("dedicated fallback-rate cap = %d, want a tightened value < 24 (dedicated capped even without a benchmark)", got)
	}
}

// TestQualityCapDisabledKeepsFlatCap: with the cap off, the legacy flat
// token-budget fallback (24) applies unchanged.
func TestQualityCapDisabledKeepsFlatCap(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	reg.SetQualityConcurrencyCap(false, 2.0, 15, 4)
	p := qualityProvider(t, reg, "gemma-box", gemmaBuild, 23)
	budgetSlot(p, 2.6)
	if got := effCap(reg, p, gemmaBuild); got != 24 {
		t.Fatalf("effective cap = %d, want 24 (cap disabled → flat fallback)", got)
	}
}

// TestQualityCapTakesMinOfReportedAndQuality: the effective cap is the MINIMUM of
// the provider-reported per-slot cap and the quality cap. A provider that reports
// a LOOSE cap (8) for a slow model is still held to the quality bar (2); a
// provider that reports a TIGHTER cap (1) than quality binds at 1. Neither path
// over-admits.
func TestQualityCapTakesMinOfReportedAndQuality(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "")

	// Slow model, provider reports 8 (above its quality batch) -> quality binds at 2.
	loose := qualityProvider(t, reg, "loose", gemmaBuild, 23)
	loose.Mu().Lock()
	loose.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	loose.BackendCapacity.Slots[0].MaxConcurrency = 8
	loose.Mu().Unlock()
	if got := effCap(reg, loose, gemmaBuild); got != 2 {
		t.Fatalf("effective cap = %d, want 2 (provider-reported 8 is looser than quality 2 → quality binds)", got)
	}

	// Fast model, provider reports 1 (tighter than its high quality batch) -> 1 binds.
	tight := qualityProvider(t, reg, "tight", qwenBuild, 57)
	tight.Mu().Lock()
	tight.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	tight.BackendCapacity.Slots[0].MaxConcurrency = 1
	tight.Mu().Unlock()
	if got := effCap(reg, tight, qwenBuild); got != 1 {
		t.Fatalf("effective cap = %d, want 1 (provider-reported 1 is tighter than quality → provider binds)", got)
	}
}

// TestQualityCapAppliedAtAdmitRecheck: the FINAL admit re-check (providerCanAdmitLockedEx,
// used by ReserveProviderEx after selection) must apply the quality cap too — otherwise
// a heartbeat that bumps load between snapshot and reservation lets a box past its
// quality cap be over-admitted via the legacy flat-cap re-check (TOCTOU).
func TestQualityCapAppliedAtAdmitRecheck(t *testing.T) {
	preparation := &reservationPreparationFixture{}
	reg := newQualityRegistry(testLogger(), func(deps *production.Dependencies) {
		deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
			preparation.planner = planner
			return preparation
		}
	})
	reg.SetDedicatedModels([]string{"gemma-4"})
	enableQualityCap(t, reg, "")
	p := qualityProvider(t, reg, "gemma", gemmaBuild, 23)
	budgetSlot(p, 2.6)

	admit := func() bool {
		selected, _ := reg.ReserveProviderEx(gemmaBuild, &production.PendingRequest{RequestID: "admit-check", Model: gemmaBuild})
		if selected != nil {
			selected.RemovePending("admit-check")
		}
		return selected != nil
	}

	// Under the cap (1 in flight, cap 2) → admit re-check passes.
	p.AddPending(&production.PendingRequest{RequestID: "a", Model: gemmaBuild})
	if !admit() {
		t.Fatal("admit re-check rejected a box below its quality cap (1 < 2)")
	}
	// At the cap (2 in flight) → admit re-check must reject (not the flat 24).
	rechecked := false
	preparation.after = func(string) {
		rechecked = true
		p.AddPending(&production.PendingRequest{RequestID: "b", Model: gemmaBuild})
	}
	if admit() {
		t.Fatal("admit re-check admitted a box already at its quality cap (2); final re-check must apply the cap")
	}
	if !rechecked {
		t.Fatal("reservation did not reach the prepared scan-to-commit handoff")
	}
}
