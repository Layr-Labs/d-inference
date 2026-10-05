package registry_test

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCheckpointSSDStageCostCompetesWithColdCapacityAndLoad(t *testing.T) {
	for _, tc := range []struct {
		name, want                          string
		stage, prefill, coldPrefill, decode float64
		queue, backlog                      int
		full, onlyHolder                    bool
		maxTTFT                             float64
		afterScanPrefill                    float64
		// nearTie and path describe the committed decision. A credited holder
		// with a cold peer inside the near-tie band wins through the credit;
		// a restore penalty or a peer beyond the band leaves a unique minimum.
		nearTie int
		path    production.SelectionPath
	}{
		{name: "expensive_stage_loses", want: "cold", stage: 1200, prefill: 5000, coldPrefill: 4800, decode: 100, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "useful_hit_wins", want: "ssd", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "queue_outweighs_hit", want: "cold", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, queue: 2, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "maximum_output_does_not_dominate_first_content", want: "ssd", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 20, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "output_reservation_is_not_a_serial_queue", want: "ssd", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, backlog: 1000, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "full_N_still_required", want: "cold", stage: 100, prefill: 5000, coldPrefill: 4800, decode: 100, full: true, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "cache_applied_before_deadline", want: "ssd", stage: 100, prefill: 1000, coldPrefill: 5000, decode: 100, maxTTFT: 3000, nearTie: 1, path: production.SelectionUniqueMin},
		{name: "only_expensive_holder_still_serves", want: "ssd", stage: 900, prefill: 5000, decode: 100, onlyHolder: true, nearTie: 1, path: production.SelectionUniqueMin},
		// A rate change during reservation changes both cold prefill and cache
		// savings, forcing the atomic commit to rescan before dispatch.
		{name: "reservation_reprices_changed_rate", want: "ssd", stage: 900, prefill: 5000, coldPrefill: 4000, decode: 100, afterScanPrefill: 1000, nearTie: 1, path: production.SelectionUniqueMin},
	} {
		t.Run(tc.name, func(t *testing.T) {
			preparation := &reservationPreparationFixture{}
			history := &measurements.History{}
			r, fixture := newCheckpointPricingFixture(t, production.Dependencies{
				Reservations: func(planner *production.ReservationPlanner) production.ReservationPreparation {
					preparation.planner = planner
					return preparation
				},
				Measurements: func(id string) *measurements.History {
					if id == "ssd" {
						return history
					}
					return &measurements.History{}
				},
			})
			r.Disconnect("provider-a")
			checkpointPricingUncap(t, r)
			capability := checkpointPricingCapability(1)
			holder := checkpointPricingProvider(t, r, "ssd", capability)
			holder.Mu().Lock()
			holder.PrefillTPS = tc.prefill
			holder.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.prefill
			holder.BackendCapacity.Slots[0].ObservedDecodeTPS = tc.decode
			holder.BackendCapacity.Slots[0].NumWaiting = tc.queue
			holder.BackendCapacity.Slots[0].MaxTokensPotential = int64(tc.backlog)
			holder.Mu().Unlock()
			if tc.maxTTFT > 0 {
				checkpointPricingFreshIdle(holder, history, tc.prefill)
			}
			if !tc.onlyHolder {
				cold := makeSchedulerProvider(t, r, "cold", "model", 100)
				cold.Mu().Lock()
				cold.PrefillTPS = tc.coldPrefill
				cold.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.coldPrefill
				cold.Mu().Unlock()
				if tc.afterScanPrefill > 0 {
					// A pending request on another model (750 ms) keeps the cold
					// peer inside the band while making the first scan's
					// least-busy choice of the penalized holder deterministic.
					cold.AddPending(&production.PendingRequest{RequestID: "other-model-turn", Model: "other-model", RequestedMaxTokens: 1})
				}
			}
			checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			plan := fixture.plans.bind(exactTestPlan(checkpoint, floor))
			_, ready := checkpointPricingAttempt(t, r, holder, capability, "donor", plan, 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved, ready.StageMs = checkpoint.TokenCount, tc.stage
			if !r.ApplyPrefixCacheReadyV2(holder.ID, ready) {
				t.Fatal("request-bound durable checkpoint receipt rejected")
			}
			request := &production.PendingRequest{RequestID: "repeat", Model: "model", CachePlan: plan,
				EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128, MaxTTFTMs: tc.maxTTFT}
			if tc.full {
				holder.Mu().Lock()
				// The suffix fits, but the complete accepted N promise does not.
				holder.BackendCapacity.Slots[0].ActiveTokenBudgetMax = int64(plan.PromptTokenCount + request.RequestedMaxTokens - 1)
				holder.Mu().Unlock()
			}
			scans := 0
			if tc.afterScanPrefill > 0 {
				preparation.after = func(string) {
					scans++
					if scans == 1 {
						holder.Mu().Lock()
						holder.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.afterScanPrefill
						holder.Mu().Unlock()
					}
				}
			}
			selected, decision := r.ReserveProviderEx("model", request)
			if selected == nil || selected.ID != tc.want || decision.NearTiePoolSize != tc.nearTie || decision.SelectionPath != tc.path {
				t.Fatalf("restore/load/capacity ranking selected %v, want %s near=%d path=%s: %+v", selected, tc.want, tc.nearTie, tc.path, decision)
			}
			t.Cleanup(func() { selected.RemovePending(request.RequestID); r.SetProviderIdle(selected.ID) })
			if !request.CacheOpportunity.Evaluated || request.CacheOpportunity.MatchingHolders != 1 || request.CacheOpportunity.ValidHolders != 1 {
				t.Fatalf("reservation lost opportunity evidence: %+v", request.CacheOpportunity)
			}
			wantReason := "selected"
			switch {
			case tc.full:
				wantReason = "holder_unavailable"
			case tc.onlyHolder || tc.name == "expensive_stage_loses":
				wantReason = "holder_no_positive_credit"
			case tc.want == "cold":
				wantReason = "holder_not_selected"
			}
			if got := request.CacheOpportunityReason(); got != wantReason {
				t.Fatalf("opportunity reason=%s want=%s: %+v", got, wantReason, request.CacheOpportunity)
			}

			sum := decision.StateMs + decision.QueueMs + decision.PendingMs + decision.BacklogMs + decision.ThisReqMs + decision.HealthMs + decision.CapacityRateMs - decision.CacheDiscountMs
			if math.Abs(sum-decision.CostMs) > 1e-8 {
				t.Fatalf("decision cost breakdown lost net stage cost: %+v", decision)
			}
			if tc.full && decision.CapacityRejections != 1 {
				t.Fatal("cache benefit bypassed complete request capacity")
			}
			if tc.maxTTFT > 0 && (decision.FirstContent.Status != production.FirstContentFeasible || decision.FirstContent.ConservativeMs > tc.maxTTFT) {
				t.Fatal("validated cache work was not applied before deadline classification")
			}
			if tc.afterScanPrefill > 0 && (scans < 2 || decision.ScanCount < 2 || decision.CacheEstimatedTTFTSavedMs < 3000 || decision.CacheEstimatedTTFTSavedMs > 3196) {
				t.Fatalf("reservation did not reprice the current provider rate: scans=%d %+v", scans, decision)
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
