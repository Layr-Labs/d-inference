package registry

import (
	"testing"
	"time"
)

func TestCacheHintRejectsRetiredPlansAndCapturedGeneration(t *testing.T) {
	for _, mode := range []string{CacheRoutingOn, CacheRoutingOff} {
		t.Run(mode, func(t *testing.T) {
			r, p, capability := exactTestRegistry(t)
			oldPlan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))
			_, ready := checkpointTestAttempt(t, r, p, capability, "old-donor", oldPlan, 1)
			if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("initial durable holder rejected")
			}
			hints := r.cacheRoutingHints("model", oldPlan, r.cacheRouting, r.cacheRouteKeys.route, CacheRoutingOn, time.Now())
			oldHint, exists := hints[p.ID]
			if !exists || !oldHint.currentForProvider(p, "model") {
				t.Fatal("current-generation hint was not executable")
			}
			if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
				t.Fatal(err)
			}
			if oldHint.currentForProvider(p, "model") {
				t.Fatal("captured hint survived configuration retirement")
			}
			// Commit uses the same provider-locked fence; it must not preserve a cost
			// adjustment captured before retirement even if the capability is unchanged.
			candidate := &routingCandidate{provider: p, snapshot: routingSnapshot{prefillTPS: 1000}, pricedPromptTokens: 4096, prefillCostMs: 4096, costMs: 5000, breakdown: costBreakdown{ThisReqMs: 5000, Total: 5000}}
			applyServiceHint(r, candidate, oldHint)
			if candidate.costMs != 5000 || candidate.breakdown.CacheDiscountMs != 0 {
				t.Fatal("retired hint affected reservation pricing")
			}
			if mode == CacheRoutingOff {
				return
			}
			freshPlan := boundTestCachePlan(r, oldPlan)
			_, freshReady := checkpointTestAttempt(t, r, p, capability, "new-donor", freshPlan, 1)
			if !r.ApplyPrefixCacheReadyV2(p.ID, freshReady) {
				t.Fatal("new generation could not learn identical-content holder")
			}
			query := func(plan CachePlan) map[string]cacheRoutingHint {
				return r.cacheRoutingHints("model", plan, r.cacheRouting, r.cacheRouteKeys.route, CacheRoutingOn, time.Now())
			}
			if len(query(oldPlan)) != 0 {
				t.Fatal("retired plan inherited replacement-generation holder despite Prepare refusal")
			}
			unbound := freshPlan
			unbound.generation = nil
			if len(query(unbound)) != 0 {
				t.Fatal("unbound synthetic plan reached holder index")
			}
			freshHints := query(freshPlan)
			if len(freshHints) != 1 || !freshHints[p.ID].currentForProvider(p, "model") {
				t.Fatal("fresh generation lost valid identical-content hint")
			}
			applyServiceHint(r, candidate, freshHints[p.ID])
			if candidate.breakdown.CacheDiscountMs <= 0 || candidate.costMs >= 5000 {
				t.Fatal("fresh hint did not affect ordinary cache cost")
			}
		})
	}
}
