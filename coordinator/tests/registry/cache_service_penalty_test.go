package registry_test

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"math"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func TestCacheServiceCostPenaltyLogIsSigned(t *testing.T) {
	r, c, hint := serviceCostFixture(t, 1000, 0, 0)
	hint.StageMs = 5000
	applyServiceHint(r, c, hint)
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, &slog.HandlerOptions{Level: slog.LevelDebug}))
	selection.LogDecision(logger, func() selection.DecisionLog {
		return selection.DecisionLog{RequestID: "repeat", Model: "model", Winner: c.provider.ID,
			Breakdown: c.Breakdown, Path: production.SelectionUniqueMin.String(), CacheTier: c.Tier,
			CacheEstimatedTTFTSavedMs: c.EstimatedTTFTSavedMs, Candidates: 1}
	})
	var record map[string]any
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record["selection_path"] != production.SelectionUniqueMin.String() {
		t.Fatalf("selection_path = %v", record["selection_path"])
	}
	if record["cache_tier"] != "ssd" || record["cache_estimated_ttft_saved_ms"] != float64(-904) ||
		record["cache_discount_ms"] != float64(0) || record["this_req_ms"] != float64(12904) {
		t.Fatalf("restore overhead indistinguishable from a missing hint: %s", output.Bytes())
	}
}

func TestCacheServiceCostCanCreditAllChargedPrefill(t *testing.T) {
	r, c, hint := serviceCostFixture(t, 1000, 0, 0)
	c.provider.PrefixCacheMemoryModels = c.provider.PrefixCacheV2Models
	c.provider.PrefixCacheV2Models = nil
	hint.Tier, hint.StageMs, hint.PrefillTokensSaved = "memory", 0, c.PricedPromptTokens
	c.CostMs, c.Breakdown.ThisReqMs, c.Breakdown.Total = c.PrefillCostMs, c.PrefillCostMs, c.PrefillCostMs
	applyServiceHint(r, c, hint)
	if c.CostMs != 0 || c.Breakdown.Total != 0 || c.Breakdown.CacheDiscountMs != c.PrefillCostMs {
		t.Fatal("full prefill credit was lost at zero residual cost")
	}
}

func TestCacheServiceCostIncludesNetStagePenalty(t *testing.T) {
	for _, tc := range []struct {
		name, tier                       string
		weight, stage, multiplier, saved float64
	}{
		{"fresh_ssd", "ssd", 1, 5000, 1, -904},
		{"aged_ssd", "ssd", .25, 1500, 1, -476},
		{"long_prompt", "ssd", .25, 1500, 2, -476},
		{"resident_restore", "memory", 1, 5000, 1, -904},
		{"break_even", "ssd", 1, 4096, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, c, hint := serviceCostFixture(t, 1000, 1, 1)
			c.PrefillCostMs *= tc.multiplier
			c.Breakdown.ThisReqMs = c.PrefillCostMs + 2000
			c.Breakdown.StateMs, c.Breakdown.BacklogMs = 60000, 3000
			c.Breakdown.HealthMs, c.Breakdown.CapacityRateMs = 400, 500
			c.Breakdown.TTFTMs, c.Breakdown.RawTTFTMs = 10000, 10000
			before := c.Breakdown
			c.CostMs = before.StateMs + before.QueueMs + before.PendingMs + before.BacklogMs + before.ThisReqMs + before.HealthMs + before.CapacityRateMs
			c.Breakdown.Total = c.CostMs
			base := c.CostMs
			hint.EvidenceWeight, hint.StageMs, hint.Tier = tc.weight, tc.stage, tc.tier
			if tc.tier == "memory" {
				c.provider.PrefixCacheMemoryModels = c.provider.PrefixCacheV2Models
				c.provider.PrefixCacheV2Models = nil
			}
			// Limits cap benefits; they must not erase actual restore overhead.
			r.maxDiscountMs, r.maxCostFraction = f64(0), f64(0)
			applyServiceHint(r, c, hint)
			penalty := -tc.saved * tc.multiplier
			if c.CostMs != base+penalty || c.Breakdown.Total != c.CostMs ||
				c.Breakdown.ThisReqMs != before.ThisReqMs+penalty || c.Breakdown.CacheDiscountMs != 0 ||
				c.EstimatedTTFTSavedMs != tc.saved {
				t.Fatalf("net stage cost lost or counted twice: saved=%g cost=%g base=%g breakdown=%+v", c.EstimatedTTFTSavedMs, c.CostMs, base, c.Breakdown)
			}
			if c.Breakdown.StateMs != before.StateMs || c.Breakdown.QueueMs != before.QueueMs ||
				c.Breakdown.PendingMs != before.PendingMs || c.Breakdown.BacklogMs != before.BacklogMs ||
				c.Breakdown.HealthMs != before.HealthMs || c.Breakdown.CapacityRateMs != before.CapacityRateMs ||
				c.Breakdown.TTFTMs != before.TTFTMs || c.Breakdown.RawTTFTMs != before.RawTTFTMs {
				t.Fatalf("restore penalty changed another cost or admission term: %+v", c.Breakdown)
			}
			if tc.saved < 0 && c.Tier != tc.tier {
				t.Fatal("penalty lost its executable cache tier")
			}
		})
	}
}

func TestCacheServiceCostPenaltyPreservesNearTieRanking(t *testing.T) {
	r, warm, hint := serviceCostFixture(t, 1000, 0, 0)
	hint.StageMs = 4136 // 40 ms slower than recomputing the matched prefix.
	cold := serviceColdCandidate("cold", 10900, 1, 1, 0)
	applyServiceHint(r, warm, hint)
	for _, pool := range [][]*serviceCostCandidate{{warm, cold}, {cold, warm}} {
		winner, runnerUp, near, path := selectServiceCandidate(pool)
		if winner != cold || runnerUp != warm || near != 1 || path != production.SelectionUniqueMin {
			t.Fatalf("near-tie load spreading ignored restore overhead: winner=%s near=%d path=%v", winner.provider.ID, near, path)
		}
	}
}

func TestCacheServiceCostInvalidPenaltyDoesNotChangeScore(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*serviceCostCandidate, *production.CacheRoutingHint)
	}{
		{"missing", func(_ *serviceCostCandidate, h *production.CacheRoutingHint) { *h = production.CacheRoutingHint{} }},
		{"rotated", func(c *serviceCostCandidate, _ *production.CacheRoutingHint) { c.revision.Advance() }},
		{"expired", func(_ *serviceCostCandidate, h *production.CacheRoutingHint) { h.EvidenceWeight = 0 }},
		{"negative_stage", func(_ *serviceCostCandidate, h *production.CacheRoutingHint) { h.StageMs = -1 }},
		{"infinite_stage", func(_ *serviceCostCandidate, h *production.CacheRoutingHint) { h.StageMs = math.Inf(1) }},
		{"nan_weight", func(_ *serviceCostCandidate, h *production.CacheRoutingHint) { h.EvidenceWeight = math.NaN() }},
		{"unbounded_weight", func(_ *serviceCostCandidate, h *production.CacheRoutingHint) { h.EvidenceWeight = 2 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, c, hint := serviceCostFixture(t, 1000, 0, 0)
			hint.StageMs = 5000
			tc.edit(c, &hint)
			before := *c
			applyServiceHint(r, c, hint)
			if c.CostMs != before.CostMs || c.Breakdown != before.Breakdown || c.Tier != "" || c.EstimatedTTFTSavedMs != 0 {
				t.Fatal("missing, stale or invalid evidence changed the candidate")
			}
		})
	}
}
