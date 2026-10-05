package registry_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheServiceCostBalancesQueueAndHardware(t *testing.T) {
	for _, tc := range []struct {
		name           string
		rate           float64
		queue, pending int
		wantWarm       bool
	}{
		{"idle_cache", 1000, 0, 0, true},
		// Queued prefill outweighs reuse; output reservations are irrelevant.
		{"large_queue", 1000, 2, 2, false},
		// Cache-adjusted delivery is within the 100 ms fast group.
		{"slower_cached_hardware_near_tie", 600, 0, 0, true},
		// Slower prefill remains outside the fast group despite valid reuse.
		{"slower_cached_hardware", 400, 0, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, warm, hint := serviceCostFixture(t, tc.rate, tc.queue, tc.pending)
			cold := serviceColdCandidate("cold", 11100, 0, 0, 0)
			applyServiceHint(r, warm, hint)
			if warm.Breakdown.CacheDiscountMs <= 1000 {
				t.Fatal("unconfigured fixed cap still clips multi-second savings")
			}
			winner, _, _, _ := selectServiceCandidate([]*serviceCostCandidate{cold, warm})
			if (winner == warm) != tc.wantWarm {
				t.Fatalf("warm=%g cold=%g selected=%s", warm.CostMs, cold.CostMs, winner.provider.ID)
			}
		})
	}
}

func TestCacheServiceCreditPreservesNonPrefillTerms(t *testing.T) {
	r, c, hint := serviceCostFixture(t, 1000, 1, 1)
	// A doubled prefill component models the existing long-prompt multiplier.
	// Its load multiplier, plus decode/queue/backlog/health, must survive.
	c.PrefillCostMs *= 2
	c.Breakdown.ThisReqMs = c.PrefillCostMs + 2000
	c.Breakdown.StateMs = 60000
	c.Breakdown.BacklogMs = 3000
	c.Breakdown.HealthMs = 400
	c.Breakdown.CapacityRateMs = 500
	retained := c.Breakdown.StateMs + c.Breakdown.QueueMs + c.Breakdown.PendingMs + c.Breakdown.BacklogMs + c.Breakdown.HealthMs + c.Breakdown.CapacityRateMs + 2000
	c.CostMs = retained + c.PrefillCostMs
	before := c.Breakdown
	hint.PrefillTokensSaved = 20000 // Cannot remove more than the 10k charged prompt.
	hint.EvidenceWeight = .5
	hint.StageMs = 1000
	applyServiceHint(r, c, hint)
	if c.EstimatedTTFTSavedMs != 4000 || c.Breakdown.CacheDiscountMs != 8000 {
		t.Fatalf("stage was discounted or prefill amplification drifted: %+v", c.Breakdown)
	}
	if c.CostMs != retained+12000 || c.Breakdown.ThisReqMs != before.ThisReqMs ||
		c.Breakdown.StateMs != before.StateMs || c.Breakdown.QueueMs != before.QueueMs ||
		c.Breakdown.PendingMs != before.PendingMs || c.Breakdown.BacklogMs != before.BacklogMs ||
		c.Breakdown.HealthMs != before.HealthMs || c.Breakdown.CapacityRateMs != before.CapacityRateMs {
		t.Fatalf("cache credit removed non-prefill cost: %+v", c.Breakdown)
	}
}

func TestCacheServiceCostRejectsUnusableOrStaleEvidence(t *testing.T) {
	for _, action := range []string{"zero_rate", "nan_rate", "zero_weight", "expired", "nan_stage", "zero_ssd_stage", "rotated", "negative_tokens", "wrong_tier"} {
		t.Run(action, func(t *testing.T) {
			r, c, hint := serviceCostFixture(t, 1000, 0, 0)
			switch action {
			case "zero_rate":
				c.Rates.StaticPrefill = 0
			case "nan_rate":
				c.Rates.StaticPrefill = math.NaN()
			case "zero_weight":
				hint.EvidenceWeight = 0
			case "expired":
				now := time.Now()
				hint.EvidenceWeight = cachepolicy.EvidenceWeight(now.Add(-time.Minute), now, now)
			case "nan_stage":
				hint.StageMs = math.NaN()
			case "zero_ssd_stage":
				hint.StageMs = 0
			case "rotated":
				c.revision.Advance()
			case "negative_tokens":
				hint.PrefillTokensSaved = -1
			case "wrong_tier":
				hint.Tier = "remote"
			}
			before := c.CostMs
			applyServiceHint(r, c, hint)
			if c.CostMs != before || c.Breakdown.CacheDiscountMs != 0 {
				t.Fatal("unusable hint changed cost")
			}
		})
	}
}

func TestCacheServiceCostExplicitLimitsAndMemoryStage(t *testing.T) {
	for _, limit := range []float64{0, 1000} {
		r, c, hint := serviceCostFixture(t, 1000, 0, 0)
		r.maxDiscountMs = f64(limit)
		applyServiceHint(r, c, hint)
		if c.Breakdown.CacheDiscountMs != limit {
			t.Fatal("explicit millisecond cap lost")
		}
	}
	r, c, hint := serviceCostFixture(t, 1000, 0, 0)
	r.maxCostFraction = f64(.01)
	applyServiceHint(r, c, hint)
	if c.Breakdown.CacheDiscountMs != 120 {
		t.Fatal("explicit fraction cap lost")
	}
	r, c, hint = serviceCostFixture(t, 1000, 0, 0)
	c.provider.PrefixCacheMemoryModels = c.provider.PrefixCacheV2Models
	c.provider.PrefixCacheV2Models = nil // This fixture models executable resident-only reuse.
	hint.Tier, hint.StageMs = "memory", 0
	applyServiceHint(r, c, hint)
	if c.Breakdown.CacheDiscountMs != 4096 || c.Tier != "memory" {
		t.Fatal("resident zero-stage credit lost")
	}
}

func TestCacheEvidenceAgePolicy(t *testing.T) {
	now := time.Now()
	updatedAt, expiresAt := now, now.Add(time.Minute)
	for _, tc := range []struct {
		age  time.Duration
		want float64
	}{{-time.Second, 1}, {0, 1}, {30 * time.Second, .5}, {time.Minute, 0}, {2 * time.Minute, 0}} {
		if got := cachepolicy.EvidenceWeight(updatedAt, expiresAt, now.Add(tc.age)); got != tc.want {
			t.Fatalf("age=%v weight=%g want=%g", tc.age, got, tc.want)
		}
	}
	if cachepolicy.EvidenceWeight(time.Time{}, time.Time{}, now) != 0 {
		t.Fatal("missing lifetime claimed fresh evidence")
	}
}

func TestCacheServiceCostPricesProviderAlignedLongestCheckpoint(t *testing.T) {
	r, fixture := newCheckpointPricingFixture(t)
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	r.Disconnect("provider-a")
	checkpointPricingUncap(t, r)
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	p := checkpointPricingProvider(t, r, "durable", capability)
	p.Mu().Lock()
	p.PrefillTPS = 1000
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	p.Mu().Unlock()
	short, long := cacheFlowAnchor(16, "c"), cacheFlowAnchor(32, "d")
	plan := fixture.plans.bind(cacheFlowPlan(short, long, cacheFlowAnchor(36, "e")))
	_, ready := checkpointPricingAttempt(t, r, p, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{short}
	ready.ExpectedPrefillTokensSaved, ready.StageMs = short.TokenCount, 100
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("first durable file proof rejected")
	}
	second := *ready
	second.ReadyAnchors = []protocol.PrefixCacheAnchor{long}
	second.ExpectedPrefillTokensSaved, second.StageMs, second.CacheSeq = long.TokenCount, 5000, 3
	if !r.ApplyPrefixCacheReadyV2(p.ID, &second) {
		t.Fatal("later durable file proof rejected")
	}
	hints, _ := fixture.query.Query("model", plan, fixture.routeKey, production.CacheRoutingOn, time.Now())
	hint := hints[p.ID]
	if hint.CachedTokens != long.TokenCount {
		t.Fatalf("query did not retain the provider-aligned longest endpoint: %+v", hint)
	}
	repeat := &production.PendingRequest{RequestID: "repeat", Model: "model", CachePlan: plan,
		EstimatedPromptTokens: 10000, RequestedMaxTokens: 128}
	selected, decision := r.ReserveProviderEx("model", repeat)
	if selected != p {
		t.Fatalf("no durable provider selected: %+v", decision)
	}
	defer func() { p.RemovePending(repeat.RequestID); r.SetProviderIdle(p.ID) }()
	// The 4096/100ms file saves ~3996ms; the 8192/5000ms file saves ~3192ms.
	// The provider chooses the longest file, so do not price the cheaper short
	// checkpoint. Small receipt-age decay is allowed.
	if decision.CacheEstimatedTTFTSavedMs < 3186 || decision.CacheEstimatedTTFTSavedMs > 3192 || decision.CacheTier != "ssd" {
		t.Fatalf("reservation did not price the longest executable checkpoint: %+v", decision)
	}
}
