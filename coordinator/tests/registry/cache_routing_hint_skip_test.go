package registry_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The scan's early guard matches the holder index's eligibility predicate.
// Off/missing-plan/missing-key paths do no content lookup and return nil hints;
// an ordinary holder miss also returns nil, while selection stays active.
func TestScanProviderReservationSkipsHintsExactlyWhenTrackerWould(t *testing.T) {
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	newPR := func(with bool) *production.PendingRequest {
		pr := &production.PendingRequest{RequestID: "hint-skip", Model: "model", RequestedMaxTokens: 16}
		if with {
			pr.CachePlan = plan
		}
		return pr
	}

	t.Run("mode off", func(t *testing.T) {
		_, f := newCheckpointPricingFixture(t)
		pr := newPR(true)
		pr.CachePlan = f.plans.bind(pr.CachePlan)
		preparation := production.CacheHintPreparation{Query: f.query, Mode: production.CacheRoutingOff, RouteKey: f.routeKey}
		result := preparation.Prepare("model", pr.CachePlan, time.Now())
		result.Apply(pr)
		if result.Hints != nil {
			t.Fatal("cache routing off must leave hints nil")
		}
		if pr.CacheSelectionMode != "" {
			t.Fatalf("selection mode = %q, want empty when off", pr.CacheSelectionMode)
		}
	})

	t.Run("on without plan", func(t *testing.T) {
		_, f := newCheckpointPricingFixture(t)
		pr := newPR(false)
		preparation := production.CacheHintPreparation{Query: f.query, Mode: production.CacheRoutingOn, RouteKey: f.routeKey}
		result := preparation.Prepare("model", pr.CachePlan, time.Now())
		result.Apply(pr)
		if result.Hints != nil {
			t.Fatal("a request without a cache plan must get no hints")
		}
	})

	t.Run("on with plan", func(t *testing.T) {
		_, f := newCheckpointPricingFixture(t)
		pr := newPR(true)
		pr.CachePlan = f.plans.bind(pr.CachePlan)
		preparation := production.CacheHintPreparation{Query: f.query, Mode: production.CacheRoutingOn, RouteKey: f.routeKey}
		result := preparation.Prepare("model", pr.CachePlan, time.Now())
		result.Apply(pr)
		if result.Hints != nil {
			t.Fatal("active plan without holders must skip capability work and leave hints nil")
		}
		if pr.CacheSelectionMode != "active" {
			t.Fatalf("selection mode = %q, want active", pr.CacheSelectionMode)
		}
	})

	t.Run("on with plan but no route key", func(t *testing.T) {
		_, f := newCheckpointPricingFixture(t)
		pr := newPR(true)
		pr.CachePlan = f.plans.bind(pr.CachePlan)
		preparation := production.CacheHintPreparation{Query: f.query, Mode: production.CacheRoutingOn, RouteKey: nil}
		result := preparation.Prepare("model", pr.CachePlan, time.Now())
		result.Apply(pr)
		if result.Hints != nil {
			t.Fatal("no route key must leave hints nil (matchingHolders would return nil)")
		}
	})

	t.Run("on with plan but nil tracker", func(t *testing.T) {
		_, f := newCheckpointPricingFixture(t)
		pr := newPR(true)
		pr.CachePlan = f.plans.bind(pr.CachePlan)
		preparation := production.CacheHintPreparation{Query: nil, Mode: production.CacheRoutingOn, RouteKey: f.routeKey}
		result := preparation.Prepare("model", pr.CachePlan, time.Now()) // must not panic
		result.Apply(pr)
		if result.Hints != nil {
			t.Fatal("nil tracker must leave hints nil")
		}
	})
}
