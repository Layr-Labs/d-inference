package registry

import "testing"

// The scan's early guard matches the holder index's eligibility predicate.
// Off/missing-plan/missing-key paths do no content lookup and return nil hints;
// an ordinary holder miss also returns nil, while selection stays active.
func TestScanProviderReservationSkipsHintsExactlyWhenTrackerWould(t *testing.T) {
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	newPR := func(with bool) *PendingRequest {
		pr := &PendingRequest{RequestID: "hint-skip", Model: "model", RequestedMaxTokens: 16}
		if with {
			pr.CachePlan = plan
		}
		return pr
	}

	t.Run("mode off", func(t *testing.T) {
		r := New(testLogger())
		pr := newPR(true)
		r.scanProviderReservation("model", pr)
		if pr.cacheRoutingHints != nil {
			t.Fatal("cache routing off must leave hints nil")
		}
		if pr.CacheSelectionMode != "" {
			t.Fatalf("selection mode = %q, want empty when off", pr.CacheSelectionMode)
		}
	})

	t.Run("on without plan", func(t *testing.T) {
		r, _, _ := exactTestRegistry(t)
		pr := newPR(false)
		r.scanProviderReservation("model", pr)
		if pr.cacheRoutingHints != nil {
			t.Fatal("a request without a cache plan must get no hints")
		}
	})

	t.Run("on with plan", func(t *testing.T) {
		r, _, _ := exactTestRegistry(t)
		pr := newPR(true)
		r.scanProviderReservation("model", pr)
		if pr.cacheRoutingHints != nil {
			t.Fatal("active plan without holders must skip capability work and leave hints nil")
		}
		if pr.CacheSelectionMode != "active" {
			t.Fatalf("selection mode = %q, want active", pr.CacheSelectionMode)
		}
	})

	t.Run("on with plan but no route key", func(t *testing.T) {
		r, _, _ := exactTestRegistry(t)
		r.mu.Lock()
		r.cacheRouteKeys.route = nil
		r.mu.Unlock()
		pr := newPR(true)
		r.scanProviderReservation("model", pr)
		if pr.cacheRoutingHints != nil {
			t.Fatal("no route key must leave hints nil (matchingHolders would return nil)")
		}
	})

	t.Run("on with plan but nil tracker", func(t *testing.T) {
		r, _, _ := exactTestRegistry(t)
		r.mu.Lock()
		r.cacheRouting = nil
		r.mu.Unlock()
		pr := newPR(true)
		r.scanProviderReservation("model", pr) // must not panic
		if pr.cacheRoutingHints != nil {
			t.Fatal("nil tracker must leave hints nil")
		}
	})
}
