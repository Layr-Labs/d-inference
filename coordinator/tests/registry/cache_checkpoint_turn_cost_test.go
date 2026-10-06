package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCheckpointSSDNextTurnPricesEachMachinesExecutableEndpoint(t *testing.T) {
	for _, tc := range []struct {
		name           string
		stageB         float64
		queueA, queueB int
		want           string
		wantSavedMS    float64
	}{
		{"longer_checkpoint_wins", 100, 0, 0, "machine-b", 8092},
		{"longer_stage_cost_loses", 5000, 0, 0, "machine-a", 3976},
		{"longer_queue_cost_loses", 100, 0, 10, "machine-a", 3976},
		{"both_holders_busy_cold_fallback", 100, 10, 10, "cold", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, fixture := newCheckpointPricingFixture(t)
			r.Disconnect("provider-a")
			checkpointPricingUncap(t, r)
			capA, capB := checkpointPricingCapability(1), checkpointPricingCapability(2)
			a := checkpointPricingProvider(t, r, "machine-a", capA)
			b := checkpointPricingProvider(t, r, "machine-b", capB)
			cold := makeSchedulerProvider(t, r, "cold", "model", 100)
			for _, p := range []*production.Provider{a, b, cold} {
				p.Mu().Lock()
				p.PrefillTPS = 1000
				p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
				p.Mu().Unlock()
			}
			originalCheckpoint, originalFloor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			laterCheckpoint, nextFloor := exactTestAnchor(32, "e"), exactTestAnchor(36, "f")
			original := fixture.plans.bind(exactTestPlan(originalCheckpoint, originalFloor))
			nextTurn := fixture.plans.bind(exactTestPlan(originalCheckpoint, originalFloor, laterCheckpoint, nextFloor))
			_, readyA := checkpointPricingAttempt(t, r, a, capA, "original-on-a", original, 1)
			readyA.ReadyAnchors = []protocol.PrefixCacheAnchor{originalCheckpoint}
			readyA.ExpectedPrefillTokensSaved, readyA.StageMs = originalCheckpoint.TokenCount, 120
			_, readyB := checkpointPricingAttempt(t, r, b, capB, "turn-two-on-b", nextTurn, 1)
			readyB.ReadyAnchors = []protocol.PrefixCacheAnchor{laterCheckpoint}
			readyB.ExpectedPrefillTokensSaved, readyB.StageMs = laterCheckpoint.TokenCount, tc.stageB
			if !r.ApplyPrefixCacheReadyV2(a.ID, readyA) || !r.ApplyPrefixCacheReadyV2(b.ID, readyB) {
				t.Fatal("actual complete-checkpoint receipt rejected")
			}
			hints := fixture.hints(nextTurn, time.Now())
			if len(hints) != 2 || hints[a.ID].CachedTokens != 4096 || hints[b.ID].CachedTokens != 8192 || hints[b.ID].StageMs != tc.stageB {
				t.Fatalf("next turn did not retain each machine's exact endpoint: %+v", hints)
			}
			a.Mu().Lock()
			a.BackendCapacity.Slots[0].NumWaiting = tc.queueA
			a.Mu().Unlock()
			b.Mu().Lock()
			b.BackendCapacity.Slots[0].NumWaiting = tc.queueB
			b.Mu().Unlock()
			request := &production.PendingRequest{RequestID: "next-turn", Model: "model", CachePlan: nextTurn,
				EstimatedPromptTokens: nextTurn.PromptTokenCount, RequestedMaxTokens: 128}
			selected, decision := r.ReserveProviderEx("model", request)
			if selected == nil || selected.ID != tc.want {
				t.Fatalf("endpoint/queue/stage cost selected %v, want %s: %+v", selected, tc.want, decision)
			}
			defer func() { selected.RemovePending(request.RequestID); r.SetProviderIdle(selected.ID) }()
			if tc.wantSavedMS == 0 {
				if decision.CacheDiscountMs != 0 || decision.CacheEstimatedTTFTSavedMs != 0 || decision.CacheTier != "" {
					t.Fatalf("cold fallback inherited another machine's cache credit: %+v", decision)
				}
			} else if decision.CacheTier != "ssd" || decision.CacheDiscountMs <= 0 ||
				decision.CacheEstimatedTTFTSavedMs <= 0 || decision.CacheEstimatedTTFTSavedMs > tc.wantSavedMS {
				// Age may reduce the benefit; pure service-cost tests own its exact math.
				t.Fatalf("selected machine was not priced at its executable checkpoint: %+v", decision)
			}
		})
	}
}
