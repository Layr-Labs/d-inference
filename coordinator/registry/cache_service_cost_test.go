package registry

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func serviceCostFixture(prefillTPS float64, queue, pending int) (*Registry, *routingCandidate, cacheRoutingHint) {
	r := New(testLogger())
	capability := indexTestCapability(1)
	p := &Provider{ID: "warm", PrefixCacheProtocol: 2,
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{"model": capability}}
	prefill := 10000 / prefillTPS * 1000
	c := &routingCandidate{provider: p, snapshot: routingSnapshot{prefillTPS: prefillTPS, totalPending: pending},
		pricedPromptTokens: 10000, prefillCostMs: prefill, effectiveQueue: queue,
		breakdown: costBreakdown{ThisReqMs: prefill + 2000, QueueMs: float64(queue) * queueDepthPenaltyMs,
			PendingMs: float64(pending) * totalPendingPenaltyMs}}
	c.costMs = c.breakdown.ThisReqMs + c.breakdown.QueueMs + c.breakdown.PendingMs
	c.breakdown.Total = c.costMs
	hint := cacheRoutingHint{generation: r.cacheRouting.generation, Provider: p, Capability: capability, Tier: "ssd",
		PrefillTokensSaved: 4096, CachedTokens: 4096, StageMs: 120, EvidenceWeight: 1}
	return r, c, hint
}

func applyServiceHint(r *Registry, c *routingCandidate, hint cacheRoutingHint) {
	r.mu.RLock()
	c.provider.mu.Lock()
	r.applyCacheHintLocked(hint, "model", c)
	c.provider.mu.Unlock()
	r.mu.RUnlock()
}

func TestCacheServiceCostBalancesQueueAndHardware(t *testing.T) {
	for _, tc := range []struct {
		name           string
		rate           float64
		queue, pending int
		wantWarm       bool
	}{
		{"modest_queue", 1000, 1, 1, true},
		{"large_queue", 1000, 2, 2, false},
		{"slower_cached_hardware", 500, 0, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, warm, hint := serviceCostFixture(tc.rate, tc.queue, tc.pending)
			cold := mkCandidate("cold", 12000, 0, 0, 0)
			applyServiceHint(r, warm, hint)
			if warm.breakdown.CacheDiscountMs <= 1000 {
				t.Fatal("unconfigured fixed cap still clips multi-second savings")
			}
			winner, _, _, _ := selectRoutingCandidate([]*routingCandidate{cold, warm})
			if (winner == warm) != tc.wantWarm {
				t.Fatalf("warm=%g cold=%g selected=%s", warm.costMs, cold.costMs, winner.provider.ID)
			}
		})
	}
}

func TestCacheServiceCreditPreservesNonPrefillTerms(t *testing.T) {
	r, c, hint := serviceCostFixture(1000, 1, 1)
	// A doubled prefill component models the existing long-prompt multiplier.
	// Its load multiplier, plus decode/queue/backlog/health, must survive.
	c.prefillCostMs *= 2
	c.breakdown.ThisReqMs = c.prefillCostMs + 2000
	c.breakdown.StateMs = 60000
	c.breakdown.BacklogMs = 3000
	c.breakdown.HealthMs = 400
	c.breakdown.CapacityRateMs = 500
	retained := c.breakdown.StateMs + c.breakdown.QueueMs + c.breakdown.PendingMs + c.breakdown.BacklogMs + c.breakdown.HealthMs + c.breakdown.CapacityRateMs + 2000
	c.costMs = retained + c.prefillCostMs
	before := c.breakdown
	hint.PrefillTokensSaved = 20000 // Cannot remove more than the 10k charged prompt.
	hint.EvidenceWeight = .5
	hint.StageMs = 1000
	applyServiceHint(r, c, hint)
	if c.cacheEstimatedTTFTSavedMs != 4000 || c.breakdown.CacheDiscountMs != 8000 {
		t.Fatalf("stage was discounted or prefill amplification drifted: %+v", c.breakdown)
	}
	if c.costMs != retained+12000 || c.breakdown.ThisReqMs != before.ThisReqMs ||
		c.breakdown.StateMs != before.StateMs || c.breakdown.QueueMs != before.QueueMs ||
		c.breakdown.PendingMs != before.PendingMs || c.breakdown.BacklogMs != before.BacklogMs ||
		c.breakdown.HealthMs != before.HealthMs || c.breakdown.CapacityRateMs != before.CapacityRateMs {
		t.Fatalf("cache credit removed non-prefill cost: %+v", c.breakdown)
	}
}

func TestCacheServiceCostRejectsUnusableOrStaleEvidence(t *testing.T) {
	for _, action := range []string{"zero_rate", "nan_rate", "zero_weight", "expired", "nan_stage", "zero_ssd_stage", "rotated", "negative_tokens", "wrong_tier"} {
		t.Run(action, func(t *testing.T) {
			r, c, hint := serviceCostFixture(1000, 0, 0)
			switch action {
			case "zero_rate":
				c.snapshot.prefillTPS = 0
			case "nan_rate":
				c.snapshot.prefillTPS = math.NaN()
			case "zero_weight":
				hint.EvidenceWeight = 0
			case "expired":
				now := time.Now()
				hint.EvidenceWeight = cacheEvidenceWeight(cacheHolder{UpdatedAt: now.Add(-time.Minute), ExpiresAt: now}, now)
			case "nan_stage":
				hint.StageMs = math.NaN()
			case "zero_ssd_stage":
				hint.StageMs = 0
			case "rotated":
				c.provider.prefixCacheRevision++
			case "negative_tokens":
				hint.PrefillTokensSaved = -1
			case "wrong_tier":
				hint.Tier = "remote"
			}
			before := c.costMs
			applyServiceHint(r, c, hint)
			if c.costMs != before || c.breakdown.CacheDiscountMs != 0 {
				t.Fatal("unusable hint changed cost")
			}
		})
	}
}

func TestCacheServiceCostExplicitLimitsAndMemoryStage(t *testing.T) {
	for _, limit := range []float64{0, 1000} {
		r, c, hint := serviceCostFixture(1000, 0, 0)
		r.cacheRoutingMaxDiscountMs = f64(limit)
		applyServiceHint(r, c, hint)
		if c.breakdown.CacheDiscountMs != limit {
			t.Fatal("explicit millisecond cap lost")
		}
	}
	r, c, hint := serviceCostFixture(1000, 0, 0)
	r.cacheRoutingMaxCostFraction = f64(.01)
	applyServiceHint(r, c, hint)
	if c.breakdown.CacheDiscountMs != 120 {
		t.Fatal("explicit fraction cap lost")
	}
	r, c, hint = serviceCostFixture(1000, 0, 0)
	c.provider.PrefixCacheMemoryModels = c.provider.PrefixCacheV2Models
	c.provider.PrefixCacheV2Models = nil // This fixture models executable resident-only reuse.
	hint.Tier, hint.StageMs = "memory", 0
	applyServiceHint(r, c, hint)
	if c.breakdown.CacheDiscountMs != 4096 || c.cacheTier != "memory" {
		t.Fatal("resident zero-stage credit lost")
	}
}

func TestCacheEvidenceAgePolicy(t *testing.T) {
	now := time.Now()
	holder := cacheHolder{UpdatedAt: now, ExpiresAt: now.Add(time.Minute)}
	for _, tc := range []struct {
		age  time.Duration
		want float64
	}{{-time.Second, 1}, {0, 1}, {30 * time.Second, .5}, {time.Minute, 0}, {2 * time.Minute, 0}} {
		if got := cacheEvidenceWeight(holder, now.Add(tc.age)); got != tc.want {
			t.Fatalf("age=%v weight=%g want=%g", tc.age, got, tc.want)
		}
	}
	if cacheEvidenceWeight(cacheHolder{}, now) != 0 {
		t.Fatal("missing lifetime claimed fresh evidence")
	}
}

func TestCacheServiceCostPricesProviderAlignedLongestCheckpoint(t *testing.T) {
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction = nil, nil
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	p := checkpointTestProvider(t, r, "durable", capability)
	p.mu.Lock()
	p.PrefillTPS = 1000
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	p.mu.Unlock()
	short, long := exactTestAnchor(16, "c"), exactTestAnchor(32, "d")
	plan := boundTestCachePlan(r, exactTestPlan(short, long, exactTestAnchor(36, "e")))
	_, ready := checkpointTestAttempt(t, r, p, capability, "donor", plan, 1)
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
	hint := r.cacheRoutingHints("model", plan, r.cacheRouting, r.cacheRouteKeys.route, CacheRoutingOn, time.Now())[p.ID]
	if hint.CachedTokens != long.TokenCount {
		t.Fatalf("query did not retain the provider-aligned longest endpoint: %+v", hint)
	}
	repeat := &PendingRequest{RequestID: "repeat", Model: "model", CachePlan: plan,
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
