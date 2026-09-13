package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestCacheAffinityQuarantineRoutesToHealthyPeer(t *testing.T) {
	for _, tier := range []string{"ssd", "memory"} {
		t.Run(tier, func(t *testing.T) {
			r, _, capability := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			a := checkpointTestProvider(t, r, "machine-a", capability)
			b := checkpointTestProvider(t, r, "machine-b", capability)
			publish := func(p *Provider, capability protocol.PrefixCacheV2Capability) {
				t.Helper()
				var ssd, memory []protocol.PrefixCacheV2Capability
				if tier == "ssd" {
					ssd = []protocol.PrefixCacheV2Capability{capability}
				} else {
					memory = []protocol.PrefixCacheV2Capability{capability}
				}
				if _, err := r.UpdatePrefixCacheSnapshot(p.ID, true, 2, ssd, &memory, nil, nil); err != nil {
					t.Fatal(err)
				}
			}
			publish(a, capability)
			publish(b, capability)
			plan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(2, "c")))
			for range 2 {
				r.cacheRouting.observeCacheDemand(&plan, r.cacheRouteKeys.route, time.Now())
			}
			if plan.affinityKey == "" {
				t.Fatal("repeat demand did not produce affinity")
			}
			sequence := 0
			route := func() (*Provider, RoutingDecision) {
				t.Helper()
				sequence++
				pr := &PendingRequest{RequestID: fmt.Sprint(sequence), Model: "model", CachePlan: plan,
					EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128}
				p, decision := r.ReserveProviderEx("model", pr)
				if p == nil {
					t.Fatalf("cache quarantine blocked ordinary serving: %+v", decision)
				}
				p.RemovePending(pr.RequestID)
				r.SetProviderIdle(p.ID)
				if decision.CacheDiscountMs != 0 || decision.CacheTier != "" || pr.CacheSelectionSelected {
					t.Fatal("affinity created credit without holder evidence")
				}
				return p, decision
			}
			original, decision := route()
			if decision.SelectionPath != SelectionPrefixAffinity {
				t.Fatalf("positive control did not use affinity: %+v", decision)
			}
			healthy := a
			if original == a {
				healthy = b
			}
			r.disablePrefixCacheV2Model(original.ID, "model", tier, original, r.cacheRouting, capability)
			// Heartbeats retain the same advertised capability; they must not
			// restore affinity for an identity that failed proof validation.
			publish(original, capability)
			for range 5 {
				p, decision := route()
				if p != healthy || decision.SelectionPath != SelectionPrefixAffinity {
					t.Fatalf("quarantined affinity winner retained preference: got %s want %s, %+v", p.ID, healthy.ID, decision)
				}
			}
			r.disablePrefixCacheV2Model(healthy.ID, "model", tier, healthy, r.cacheRouting, capability)
			if _, decision := route(); decision.SelectionPath == SelectionPrefixAffinity {
				t.Fatal("all-quarantined pool retained affinity instead of ordinary routing")
			}
			rotated := capability
			rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
			publish(original, rotated)
			if p, decision := route(); p != original || decision.SelectionPath != SelectionPrefixAffinity {
				t.Fatal("new capability epoch could not seed fresh cache evidence")
			}
		})
	}
}

func TestCacheAffinityQuarantinePreservesOtherModel(t *testing.T) {
	r, p, capability, other := cacheTwoModelFixture(t)
	r.disablePrefixCacheV2Model(p.ID, capability.ModelID, "ssd", p, r.cacheRouting, capability)
	plan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(2, "c")))
	plan.ModelAggregateHash = other.ModelAggregateHash
	plan.affinityKey = "other-model-repeat"
	pr := &PendingRequest{CachePlan: plan}
	candidate := &routingCandidate{provider: p}
	r.mu.RLock()
	r.applyCacheRoutingCost(p, other.ModelID, pr, candidate)
	r.mu.RUnlock()
	if !candidate.cacheAffinityEligible {
		t.Fatal("proof quarantine on one model disabled affinity for another")
	}
}
