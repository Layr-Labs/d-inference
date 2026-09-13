package registry

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestCheckpointSSDStageCostCompetesWithColdCapacityAndLoad(t *testing.T) {
	for _, tc := range []struct {
		name, want                          string
		stage, prefill, coldPrefill, decode float64
		queue, backlog                      int
		full, onlyHolder                    bool
		maxTTFT                             float64
		afterScanPrefill                    float64
	}{
		{name: "expensive_stage_loses", want: "cold", stage: 900, prefill: 5000, coldPrefill: 4800, decode: 100},
		{name: "useful_hit_wins", want: "ssd", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100},
		{name: "queue_outweighs_hit", want: "cold", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, queue: 2},
		{name: "decode_outweighs_hit", want: "cold", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 20},
		{name: "backlog_outweighs_hit", want: "cold", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, backlog: 1000},
		{name: "full_N_still_required", want: "cold", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, full: true},
		{name: "normal_TTFT_gate_preserved", want: "cold", stage: 100, prefill: 1000, coldPrefill: 5000, decode: 100, maxTTFT: 1000},
		{name: "only_expensive_holder_still_serves", want: "ssd", stage: 900, prefill: 5000, decode: 100, onlyHolder: true},
		{name: "reservation_reprices_changed_rate", want: "cold", stage: 900, prefill: 5000, coldPrefill: 4000, decode: 100, afterScanPrefill: 1000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _, _ := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction = nil, nil
			capability := indexTestCapability(1)
			holder := checkpointTestProvider(t, r, "ssd", capability)
			holder.mu.Lock()
			holder.PrefillTPS = tc.prefill
			holder.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.prefill
			holder.BackendCapacity.Slots[0].ObservedDecodeTPS = tc.decode
			holder.BackendCapacity.Slots[0].NumWaiting = tc.queue
			holder.BackendCapacity.Slots[0].MaxTokensPotential = int64(tc.backlog)
			holder.mu.Unlock()
			if !tc.onlyHolder {
				cold := makeSchedulerProvider(t, r, "cold", "model", 100)
				cold.mu.Lock()
				cold.PrefillTPS = tc.coldPrefill
				cold.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.coldPrefill
				cold.mu.Unlock()
			}
			checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
			_, ready := checkpointTestAttempt(t, r, holder, capability, "donor", plan, 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved, ready.StageMs = checkpoint.TokenCount, tc.stage
			if !r.ApplyPrefixCacheReadyV2(holder.ID, ready) {
				t.Fatal("request-bound durable checkpoint receipt rejected")
			}
			request := &PendingRequest{RequestID: "repeat", Model: "model", CachePlan: plan,
				EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128, MaxTTFTMs: tc.maxTTFT}
			if tc.full {
				holder.mu.Lock()
				// The suffix fits, but the complete accepted N promise does not.
				holder.BackendCapacity.Slots[0].ActiveTokenBudgetMax = int64(plan.PromptTokenCount + request.RequestedMaxTokens - 1)
				holder.mu.Unlock()
			}
			scans := 0
			if tc.afterScanPrefill > 0 {
				r.reservationAfterScan = func(string) {
					scans++
					if scans == 1 {
						holder.mu.Lock()
						holder.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.afterScanPrefill
						holder.mu.Unlock()
					}
				}
			}
			selected, decision := r.ReserveProviderEx("model", request)
			if selected == nil || selected.ID != tc.want || decision.NearTiePoolSize != 1 || decision.SelectionPath != SelectionUniqueMin {
				t.Fatalf("restore/load/capacity ranking selected %v, want %s: %+v", selected, tc.want, decision)
			}
			t.Cleanup(func() { selected.RemovePending(request.RequestID); r.SetProviderIdle(selected.ID) })
			sum := decision.StateMs + decision.QueueMs + decision.PendingMs + decision.BacklogMs + decision.ThisReqMs + decision.HealthMs + decision.CapacityRateMs - decision.CacheDiscountMs
			if math.Abs(sum-decision.CostMs) > 1e-8 {
				t.Fatalf("decision cost breakdown lost net stage cost: %+v", decision)
			}
			if tc.full && decision.CapacityRejections != 1 {
				t.Fatal("cache benefit bypassed complete request capacity")
			}
			if tc.maxTTFT > 0 && decision.TTFTRejections != 1 {
				t.Fatal("cache benefit bypassed normal TTFT eligibility")
			}
			if tc.afterScanPrefill > 0 && scans < 2 {
				t.Fatal("reservation did not reprice the current provider rate")
			}
			if tc.want == "cold" {
				if decision.CacheTier != "" || decision.CacheDiscountMs != 0 || decision.CacheEstimatedTTFTSavedMs != 0 || request.CacheSelectionSelected {
					t.Fatal("cold peer inherited holder's cache accounting")
				}
			} else if tc.onlyHolder {
				if decision.CacheTier != "ssd" || decision.CacheDiscountMs != 0 || decision.CacheEstimatedTTFTSavedMs >= -80.8 || request.CacheSelectionSelected {
					t.Fatalf("necessary expensive restore was reported as a cache benefit: %+v", decision)
				}
			} else if decision.CacheTier != "ssd" || decision.CacheDiscountMs <= 0 || decision.CacheEstimatedTTFTSavedMs <= 0 || !request.CacheSelectionSelected {
				t.Fatal("useful checkpoint lost its cache-selection credit")
			}
		})
	}
}
