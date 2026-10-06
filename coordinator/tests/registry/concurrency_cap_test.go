package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// budgetSlot turns a makeSchedulerProvider box into a token-budget provider (the
// real Gemma/gpt-oss shape) so its legacy flat concurrency fallback is 24 — the
// value the quality cap must tighten. Optionally injects a collapsed observed
// decode EWMA to prove the cap reads the STATIC rate, not the observed one.
func budgetSlot(p *production.Provider, observedDecodeTPS float64) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = observedDecodeTPS
}

// enableQualityCap enables the cap with the production floor (15) and fallback
// (4), wired exactly as main.go does: the overcommit argument is whatever
// config.ReadConfig parsed — the operator's env value when set, else the legacy
// 2.0 fallback that SetQualityConcurrencyCap must override with the package
// default. overcommitEnv "" pins the env var EMPTY (treated as unset → the
// default applies), isolating the test from any ambient operator setting.
func enableQualityCap(t *testing.T, reg interface {
	SetQualityConcurrencyCap(bool, float64, float64, int)
}, overcommitEnv string) {
	t.Helper()
	key := env.EnvPrefix + "_QUALITY_CONCURRENCY_OVERCOMMIT"
	t.Setenv(key, overcommitEnv)
	reg.SetQualityConcurrencyCap(true, env.EnvFloat(key, 2.0), 15, 4)
}

// TestQualityCapSpreadsAndSheds drives the real routing path: with two dedicated
// Gemma boxes capped at 2, filling box A to its cap forces the next request onto
// idle box B; with only a capped box available, the request is rejected for
// capacity (→ the dedicated fast-429 shed upstream) instead of over-admitting.
func TestQualityCapSpreadsAndSheds(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	enableQualityCap(t, reg, "")

	a := makeSchedulerProvider(t, reg, "gemma-a", gemmaBuild, 23)
	budgetSlot(a, 2.6)

	// Fill box A to its cap (2) with coordinator-tracked pending requests.
	a.AddPending(&production.PendingRequest{RequestID: "fill-a", Model: gemmaBuild})
	a.AddPending(&production.PendingRequest{RequestID: "fill-b", Model: gemmaBuild})

	// Only the saturated box exists → no candidate (capacity-rejected, not over-admitted).
	if got := reg.ReserveProvider(gemmaBuild, &production.PendingRequest{RequestID: "req-shed", Model: gemmaBuild, RequestedMaxTokens: 128}); got != nil {
		t.Fatalf("reserved %q for a Gemma request when the only box was at its cap; want nil (shed)", got.ID)
	}

	// Add an idle box B → the request must land there, not pile onto A.
	b := makeSchedulerProvider(t, reg, "gemma-b", gemmaBuild, 23)
	budgetSlot(b, 2.6)
	got := reg.ReserveProvider(gemmaBuild, &production.PendingRequest{RequestID: "req-spread", Model: gemmaBuild, RequestedMaxTokens: 128})
	if got == nil {
		t.Fatal("ReserveProvider returned nil with an idle box available")
	}
	if got.ID != b.ID {
		t.Fatalf("selected %q, want idle box %q (load must spread, not concentrate on the capped box)", got.ID, b.ID)
	}
}

// strictQualityBatch answers qualityConcurrency's question from its DEFINING
// inequality — the largest batch B in [1, limit] whose projected per-request
// rate solo/(1+k·B) still clears floor — by search instead of algebra. It is
// deliberately not the closed form, so it can catch an off-by-one or a dropped
// clamp in floor((solo/floor - 1)/k). Like the closed form it never returns 0:
// a provider is never fully closed, even for a model that misses the floor at
// B=1.
func strictQualityBatch(solo, floor, k float64, limit int) int {
	if limit < 1 {
		limit = 1
	}
	if floor <= 0 || solo <= 0 || k <= 0 {
		return limit
	}
	best := 1
	for b := 1; b <= limit; b++ {
		if solo/(1+k*float64(b)) >= floor {
			best = b
		}
	}
	return best
}
