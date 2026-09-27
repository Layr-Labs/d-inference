package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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
			r, _, _ := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction = nil, nil
			capA, capB := indexTestCapability(1), indexTestCapability(2)
			a := checkpointTestProvider(t, r, "machine-a", capA)
			b := checkpointTestProvider(t, r, "machine-b", capB)
			cold := makeSchedulerProvider(t, r, "cold", "model", 100)
			for _, p := range []*Provider{a, b, cold} {
				p.mu.Lock()
				p.PrefillTPS = 1000
				p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
				p.mu.Unlock()
			}
			originalCheckpoint, originalFloor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			laterCheckpoint, nextFloor := exactTestAnchor(32, "e"), exactTestAnchor(36, "f")
			original := boundTestCachePlan(r, exactTestPlan(originalCheckpoint, originalFloor))
			nextTurn := boundTestCachePlan(r, exactTestPlan(originalCheckpoint, originalFloor, laterCheckpoint, nextFloor))
			_, readyA := checkpointTestAttempt(t, r, a, capA, "original-on-a", original, 1)
			readyA.ReadyAnchors = []protocol.PrefixCacheAnchor{originalCheckpoint}
			readyA.ExpectedPrefillTokensSaved, readyA.StageMs = originalCheckpoint.TokenCount, 120
			_, readyB := checkpointTestAttempt(t, r, b, capB, "turn-two-on-b", nextTurn, 1)
			readyB.ReadyAnchors = []protocol.PrefixCacheAnchor{laterCheckpoint}
			readyB.ExpectedPrefillTokensSaved, readyB.StageMs = laterCheckpoint.TokenCount, tc.stageB
			if !r.ApplyPrefixCacheReadyV2(a.ID, readyA) || !r.ApplyPrefixCacheReadyV2(b.ID, readyB) {
				t.Fatal("actual complete-checkpoint receipt rejected")
			}
			hints := memoryTestHints(r, nextTurn, time.Now())
			if len(hints) != 2 || hints[a.ID].CachedTokens != 4096 || hints[b.ID].CachedTokens != 8192 || hints[b.ID].StageMs != tc.stageB {
				t.Fatalf("next turn did not retain each machine's exact endpoint: %+v", hints)
			}
			a.mu.Lock()
			a.BackendCapacity.Slots[0].NumWaiting = tc.queueA
			a.mu.Unlock()
			b.mu.Lock()
			b.BackendCapacity.Slots[0].NumWaiting = tc.queueB
			b.mu.Unlock()
			request := &PendingRequest{RequestID: "next-turn", Model: "model", CachePlan: nextTurn,
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
