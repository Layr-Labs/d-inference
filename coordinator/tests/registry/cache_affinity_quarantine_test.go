package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	. "github.com/eigeninference/d-inference/coordinator/registry"
)

func quarantineAffinityProvider(t *testing.T, r *cacheObservationFixture, p *Provider, capability protocol.PrefixCacheV2Capability, tier string) {
	t.Helper()
	plan := exactTestPlan(exactTestAnchor(2, "c"))
	plan.ModelAggregateHash, plan.PromptContractID = capability.ModelAggregateHash, capability.PromptContractID
	pr := &PendingRequest{RequestID: "affinity-quarantine-" + p.ID, Model: capability.ModelID, CachePlan: r.plans.bind(plan)}
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	msg := fenceTestV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, exactTestAnchor(2, "d"), 1)
	msg.RequestID, msg.Tier = pr.RequestID, tier
	if result := r.ApplyPrefixCacheLookupV2Result(p.ID, msg); result.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("affinity quarantine setup did not reject the token proof: %+v", result)
	}
	r.quarantine.Quarantine(CachePlan{})
	r.quarantine.Apply()
}

func TestCacheAffinityQuarantineRoutesToHealthyPeer(t *testing.T) {
	for _, tier := range []string{"ssd", "memory"} {
		t.Run(tier, func(t *testing.T) {
			r, _, capability := newCacheObservationFixture(t)
			r.Disconnect("provider-a")
			a := checkpointPricingProvider(t, r.Registry, "machine-a", capability)
			b := checkpointPricingProvider(t, r.Registry, "machine-b", capability)
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
			plan := r.plans.bind(exactTestPlan(exactTestAnchor(2, "c")))
			for range 2 {
				plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now(), 0)
			}
			if plan.AffinityKey() == "" {
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
			quarantineAffinityProvider(t, r, original, capability, tier)
			// Heartbeats retain the same advertised capability; they must not
			// restore affinity for an identity that failed proof validation.
			publish(original, capability)
			for range 5 {
				p, decision := route()
				if p != healthy || decision.SelectionPath != SelectionPrefixAffinity {
					t.Fatalf("quarantined affinity winner retained preference: got %s want %s, %+v", p.ID, healthy.ID, decision)
				}
			}
			quarantineAffinityProvider(t, r, healthy, capability, tier)
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
	var affinity CacheAffinityEvaluator
	r, p, capability, other := cacheTwoModelFixture(t, CacheDependencies{
		Affinities: func(evaluation CacheAffinityEvaluation) CacheAffinityEvaluator {
			affinity = evaluation
			return evaluation
		},
	})
	quarantineAffinityProvider(t, r, p, capability, "ssd")
	plan := r.plans.bind(exactTestPlan(exactTestAnchor(2, "c")))
	plan.ModelAggregateHash = other.ModelAggregateHash
	repeated := plan.RepeatedPrefixTokens
	plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now(), 0)
	plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now(), 0)
	plan.RepeatedPrefixTokens = repeated
	pr := &PendingRequest{CachePlan: plan}
	p.Mu().Lock()
	eligible := affinity.EvaluateLocked(p, other.ModelID, pr.CachePlan)
	p.Mu().Unlock()
	if !eligible {
		t.Fatal("proof quarantine on one model disabled affinity for another")
	}
}

func TestCacheAffinityQuarantineBetweenScanAndCommit(t *testing.T) {
	for _, tier := range []string{"ssd", "memory"} {
		for _, withPeer := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/peer=%t", tier, withPeer), func(t *testing.T) {
				var planner *ReservationPlanner
				r, _, capability := newCacheObservationFixtureWithDependencies(t, Dependencies{
					Reservations: func(p *ReservationPlanner) ReservationPreparation {
						planner = p
						return p
					},
				})
				r.Disconnect("provider-a")
				providers := []*Provider{checkpointPricingProvider(t, r.Registry, "machine-a", capability)}
				if withPeer {
					providers = append(providers, checkpointPricingProvider(t, r.Registry, "machine-b", capability))
				}
				if tier == "memory" {
					for _, p := range providers {
						memory := []protocol.PrefixCacheV2Capability{capability}
						if _, err := r.UpdatePrefixCacheSnapshot(p.ID, true, 2, nil, &memory, nil, nil); err != nil {
							t.Fatal(err)
						}
					}
				}
				plan := r.plans.bind(exactTestPlan(exactTestAnchor(2, "c")))
				repeated := plan.RepeatedPrefixTokens
				plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now(), 0)
				plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now(), 0)
				plan.RepeatedPrefixTokens = repeated
				pr := &PendingRequest{RequestID: "quarantine-at-commit", Model: "model", CachePlan: plan,
					EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128}
				scan := planner.Prepare("model", pr).Finish()
				if scan.Provider == nil || !scan.CacheAffinityEligible {
					t.Fatal("positive control did not scan an affinity-eligible candidate")
				}
				fenced := scan.Provider
				quarantineAffinityProvider(t, r, fenced, capability, tier)
				if result := scan.Commit("model", pr); result.Provider != nil || result.Outcome != ReservationNeedsRescan {
					t.Fatalf("stale affinity committed after quarantine: provider=%v outcome=%v", result.Provider != nil, result.Outcome)
				}
				if pr.ProviderID != "" {
					t.Fatal("rescan assigned the request before fresh selection")
				}
				p, decision := r.ReserveProviderEx("model", pr)
				if p == nil {
					t.Fatal("rescan lost ordinary serving")
				}
				defer p.RemovePending(pr.RequestID)
				if withPeer && (p == fenced || decision.SelectionPath != SelectionPrefixAffinity) {
					t.Fatal("rescan did not prefer the healthy peer")
				}
				if !withPeer && (p != fenced || decision.SelectionPath == SelectionPrefixAffinity) {
					t.Fatal("sole provider could not serve without affinity")
				}
				if decision.CacheDiscountMs != 0 || pr.CacheSelectionSelected {
					t.Fatal("quarantine rescan manufactured cache credit")
				}
			})
		}
	}
}
