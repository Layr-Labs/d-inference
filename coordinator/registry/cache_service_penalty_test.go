package registry

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"math"
	"testing"
)

func TestCacheServiceCostPenaltyLogIsSigned(t *testing.T) {
	r, c, hint := serviceCostFixture(1000, 0, 0)
	hint.StageMs = 5000
	applyServiceHint(r, c, hint)
	var output bytes.Buffer
	r.logger = slog.New(slog.NewJSONHandler(&output, &slog.HandlerOptions{Level: slog.LevelDebug}))
	r.logRoutingDecision("model", &PendingRequest{RequestID: "repeat"}, c, 1)
	var record map[string]any
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record["cache_tier"] != "ssd" || record["cache_estimated_ttft_saved_ms"] != float64(-904) ||
		record["cache_discount_ms"] != float64(0) || record["this_req_ms"] != float64(12904) {
		t.Fatalf("restore overhead indistinguishable from a missing hint: %s", output.Bytes())
	}
}

func TestCacheServiceCostCanCreditAllChargedPrefill(t *testing.T) {
	r, c, hint := serviceCostFixture(1000, 0, 0)
	c.provider.PrefixCacheMemoryModels = c.provider.PrefixCacheV2Models
	c.provider.PrefixCacheV2Models = nil
	hint.Tier, hint.StageMs, hint.PrefillTokensSaved = "memory", 0, c.pricedPromptTokens
	c.costMs, c.breakdown.ThisReqMs, c.breakdown.Total = c.prefillCostMs, c.prefillCostMs, c.prefillCostMs
	applyServiceHint(r, c, hint)
	if c.costMs != 0 || c.breakdown.Total != 0 || c.breakdown.CacheDiscountMs != c.prefillCostMs {
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
			r, c, hint := serviceCostFixture(1000, 1, 1)
			c.prefillCostMs *= tc.multiplier
			c.breakdown.ThisReqMs = c.prefillCostMs + 2000
			c.breakdown.StateMs, c.breakdown.BacklogMs = 60000, 3000
			c.breakdown.HealthMs, c.breakdown.CapacityRateMs = 400, 500
			c.breakdown.TTFTMs, c.breakdown.RawTTFTMs = 10000, 10000
			before := c.breakdown
			c.costMs = before.StateMs + before.QueueMs + before.PendingMs + before.BacklogMs + before.ThisReqMs + before.HealthMs + before.CapacityRateMs
			c.breakdown.Total = c.costMs
			base := c.costMs
			hint.EvidenceWeight, hint.StageMs, hint.Tier = tc.weight, tc.stage, tc.tier
			if tc.tier == "memory" {
				c.provider.PrefixCacheMemoryModels = c.provider.PrefixCacheV2Models
				c.provider.PrefixCacheV2Models = nil
			}
			// Limits cap benefits; they must not erase actual restore overhead.
			r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction = f64(0), f64(0)
			applyServiceHint(r, c, hint)
			penalty := -tc.saved * tc.multiplier
			if c.costMs != base+penalty || c.breakdown.Total != c.costMs ||
				c.breakdown.ThisReqMs != before.ThisReqMs+penalty || c.breakdown.CacheDiscountMs != 0 ||
				c.cacheEstimatedTTFTSavedMs != tc.saved {
				t.Fatalf("net stage cost lost or counted twice: saved=%g cost=%g base=%g breakdown=%+v", c.cacheEstimatedTTFTSavedMs, c.costMs, base, c.breakdown)
			}
			if c.breakdown.StateMs != before.StateMs || c.breakdown.QueueMs != before.QueueMs ||
				c.breakdown.PendingMs != before.PendingMs || c.breakdown.BacklogMs != before.BacklogMs ||
				c.breakdown.HealthMs != before.HealthMs || c.breakdown.CapacityRateMs != before.CapacityRateMs ||
				c.breakdown.TTFTMs != before.TTFTMs || c.breakdown.RawTTFTMs != before.RawTTFTMs {
				t.Fatalf("restore penalty changed another cost or admission term: %+v", c.breakdown)
			}
			if tc.saved < 0 && c.cacheTier != tc.tier {
				t.Fatal("penalty lost its executable cache tier")
			}
		})
	}
}

func TestCacheServiceCostPenaltyPreservesNearTieRanking(t *testing.T) {
	r, warm, hint := serviceCostFixture(1000, 0, 0)
	hint.StageMs = 4136 // 40 ms slower than recomputing the matched prefix.
	cold := mkCandidate("cold", warm.costMs+20, 1, 1, 0)
	applyServiceHint(r, warm, hint)
	for _, pool := range [][]*routingCandidate{{warm, cold}, {cold, warm}} {
		winner, runnerUp, near, path := selectRoutingCandidate(pool)
		if winner != cold || runnerUp != warm || near != 1 || path != SelectionUniqueMin {
			t.Fatalf("near-tie load spreading ignored restore overhead: winner=%s near=%d path=%v", winner.provider.ID, near, path)
		}
	}
}

func TestCacheServiceCostInvalidPenaltyDoesNotChangeScore(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*routingCandidate, *cacheRoutingHint)
	}{
		{"missing", func(_ *routingCandidate, h *cacheRoutingHint) { *h = cacheRoutingHint{} }},
		{"rotated", func(c *routingCandidate, _ *cacheRoutingHint) { c.provider.prefixCacheRevision++ }},
		{"expired", func(_ *routingCandidate, h *cacheRoutingHint) { h.EvidenceWeight = 0 }},
		{"negative_stage", func(_ *routingCandidate, h *cacheRoutingHint) { h.StageMs = -1 }},
		{"infinite_stage", func(_ *routingCandidate, h *cacheRoutingHint) { h.StageMs = math.Inf(1) }},
		{"nan_weight", func(_ *routingCandidate, h *cacheRoutingHint) { h.EvidenceWeight = math.NaN() }},
		{"unbounded_weight", func(_ *routingCandidate, h *cacheRoutingHint) { h.EvidenceWeight = 2 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, c, hint := serviceCostFixture(1000, 0, 0)
			hint.StageMs = 5000
			tc.edit(c, &hint)
			before := *c
			applyServiceHint(r, c, hint)
			if c.costMs != before.costMs || c.breakdown != before.breakdown || c.cacheTier != "" || c.cacheEstimatedTTFTSavedMs != 0 {
				t.Fatal("missing, stale or invalid evidence changed the candidate")
			}
		})
	}
}
