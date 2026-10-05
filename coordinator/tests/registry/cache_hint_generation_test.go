package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheHintRejectsRetiredPlansAndCapturedGeneration(t *testing.T) {
	for _, mode := range []string{production.CacheRoutingOn, production.CacheRoutingOff} {
		t.Run(mode, func(t *testing.T) {
			r, p, capability := newCacheObservationFixture(t)
			oldPlan := r.plans.bind(exactTestPlan(exactTestAnchor(16, "c")))
			_, ready := checkpointPricingAttempt(t, r.Registry, p, capability, "old-donor", oldPlan, 1)
			if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("initial durable holder rejected")
			}
			hints := r.hints(oldPlan, time.Now())
			oldHint, exists := hints[p.ID]
			if !exists || !currentObservationHint(oldHint, p) {
				t.Fatal("current-generation hint was not executable")
			}
			if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
				t.Fatal(err)
			}
			if currentObservationHint(oldHint, p) {
				t.Fatal("captured hint survived configuration retirement")
			}
			// Commit uses the same provider-locked fence; it must not preserve a cost
			// adjustment captured before retirement even if the capability is unchanged.
			candidate := &serviceCostCandidate{provider: p, ServiceCost: cachepolicy.ServiceCost{Rates: performance.Rates{StaticPrefill: 1000}, PricedPromptTokens: 4096, PrefillCostMs: 4096, CostMs: 5000, Breakdown: cachepolicy.ServiceBreakdown{ThisReqMs: 5000, Total: 5000}}}
			limits := &serviceCostLimits{}
			applyServiceHint(limits, candidate, oldHint)
			if candidate.CostMs != 5000 || candidate.Breakdown.CacheDiscountMs != 0 {
				t.Fatal("retired hint affected reservation pricing")
			}
			if mode == production.CacheRoutingOff {
				return
			}
			freshPlan := r.plans.bind(oldPlan)
			_, freshReady := checkpointPricingAttempt(t, r.Registry, p, capability, "new-donor", freshPlan, 1)
			if !r.ApplyPrefixCacheReadyV2(p.ID, freshReady) {
				t.Fatal("new generation could not learn identical-content holder")
			}
			query := func(plan production.CachePlan) map[string]production.CacheRoutingHint {
				return r.hints(plan, time.Now())
			}
			if len(query(oldPlan)) != 0 {
				t.Fatal("retired plan inherited replacement-generation holder despite Prepare refusal")
			}
			unbound := freshPlan
			unbound = exactTestPlan(unbound.Boundaries...)
			if len(query(unbound)) != 0 {
				t.Fatal("unbound synthetic plan reached holder index")
			}
			freshHints := query(freshPlan)
			if len(freshHints) != 1 || !currentObservationHint(freshHints[p.ID], p) {
				t.Fatal("fresh generation lost valid identical-content hint")
			}
			applyServiceHint(limits, candidate, freshHints[p.ID])
			if candidate.Breakdown.CacheDiscountMs <= 0 || candidate.CostMs >= 5000 {
				t.Fatal("fresh hint did not affect ordinary cache cost")
			}
		})
	}
}
