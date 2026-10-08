package registry_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Exercise the new upstream switch against the bounded receipt-byte accounting
// and real tracker publication paths, not merely populated capability maps.
func TestCacheModelSwitchPreservesOrRevokesPublishedOwnership(t *testing.T) {
	for _, scenario := range []string{"retained", "removed", "changed_hash"} {
		t.Run(scenario, func(t *testing.T) {
			r, provider, capability := budgetLifecycleRegistry(t)
			plan := r.plans.bind(exactTestPlan(exactTestAnchor(16, "c")))
			donor, published := checkpointPricingAttempt(t, r.Registry, provider, capability, "donor", plan, 1)
			t.Cleanup(func() { r.ForgetCacheAttempt(donor) })
			if !r.ApplyPrefixCacheReadyV2(provider.ID, published) {
				t.Fatal("positive durable publication control failed")
			}
			r.MarkCacheAttemptTerminal(donor)
			late := &production.PendingRequest{RequestID: "completed-before-switch", Model: "model", CachePlan: plan}
			lateOwner := budgetLifecyclePrepare(t, r, provider, late)
			anchor := plan.Boundaries[0]
			hit := fenceTestV2Lookup(lateOwner.CacheReceiptNonce, capability, anchor, 3)
			hit.RequestID, hit.Outcome = late.RequestID, "hit"
			hit.MatchedAnchor = &anchor
			hit.ExpectedPrefillTokensSaved = anchor.TokenCount
			if !r.ApplyPrefixCacheLookupV2(provider.ID, hit) {
				t.Fatal("existing-holder hit control failed")
			}
			delayed := fenceTestV2Ready(lateOwner.CacheReceiptNonce, capability, anchor, 4)
			delayed.RequestID = late.RequestID
			t.Cleanup(func() { r.ForgetCacheAttempt(late) })
			r.MarkCacheAttemptTerminal(late)
			tracker := r.tracker()
			beforeCharge := budgetLifecycleWant(t, tracker, 2)
			if beforeCharge == 0 {
				t.Fatal("positive retained-byte charge control missing")
			}
			holders, attempts := r.CacheRoutingStateCounts()
			if holders != 1 || attempts != 2 {
				t.Fatalf("positive control holders=%d attempts=%d", holders, attempts)
			}
			generation := r.CommitProviderDrain(provider, "switch")
			if generation == 0 || !r.CompleteProviderDrain(provider, "switch", generation) {
				t.Fatal("settled drain control failed")
			}
			models := []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}}
			switch scenario {
			case "removed":
				models = []protocol.ModelInfo{{ID: "replacement", WeightHash: strings.Repeat("d", 64)}}
			case "changed_hash":
				models[0].WeightHash = strings.Repeat("d", 64)
			}
			message := &protocol.ModelsReplaceMessage{RequestID: "replacement", DrainRequestID: "switch", Models: models, ValidateOnly: true}
			if _, _, _, err := r.ReplaceProviderModels(provider, message); err != nil {
				t.Fatal(err)
			}
			if budgetLifecycleWant(t, tracker, 2) != beforeCharge {
				t.Fatal("validation-only changed retained-byte accounting")
			}
			if h, a := r.CacheRoutingStateCounts(); h != 1 || a != 2 {
				t.Fatal("validation-only changed published ownership")
			}
			message.ValidateOnly = false
			if _, _, _, err := r.ReplaceProviderModels(provider, message); err != nil {
				t.Fatal(err)
			}
			if !r.ProviderDraining(provider.ID) {
				t.Fatal("inventory commit reopened routing before readiness")
			}
			if scenario == "retained" {
				if budgetLifecycleWant(t, tracker, 2) != beforeCharge {
					t.Fatal("unchanged retained model lost its attempt accounting")
				}
				if !r.ApplyPrefixCacheReadyV2(provider.ID, delayed) {
					t.Fatal("same-identity completed attempt lost valid publication")
				}
				if h, _ := r.CacheRoutingStateCounts(); h != 1 {
					t.Fatal("retained checkpoint holder disappeared")
				}
			} else {
				budgetLifecycleWant(t, tracker, 0)
				if h, a := r.CacheRoutingStateCounts(); h != 0 || a != 0 {
					t.Fatal("removed or changed model retained tracker ownership")
				}
				if r.ApplyPrefixCacheReadyV2(provider.ID, delayed) {
					t.Fatal("late pre-switch receipt resurrected invalidated ownership")
				}
				budgetLifecycleWant(t, tracker, 0)
				// Restore the same public identity and capability. Rejection must
				// still follow from retired attempt ownership, not just a missing
				// capability map. This is the same-session remove/restore ABA case.
				nextGeneration := r.CommitProviderDrain(provider, "restore")
				if nextGeneration <= generation || !r.CompleteProviderDrain(provider, "restore", nextGeneration) {
					t.Fatal("fresh restoration barrier missing")
				}
				_, _, _, err := r.ReplaceProviderModels(provider, &protocol.ModelsReplaceMessage{
					RequestID: "restore-model", DrainRequestID: "restore",
					Models: []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}},
				})
				if err != nil {
					t.Fatal(err)
				}
				_, err = r.UpdatePrefixCacheSnapshot(provider.ID, true, 2, []protocol.PrefixCacheV2Capability{capability}, nil, nil, nil)
				if err != nil {
					t.Fatal(err)
				}
				decision := r.ApplyPrefixCacheReadyV2Result(provider.ID, delayed)
				if decision.Accepted || decision.Reason != production.CacheReceiptAttemptUnavailable {
					t.Fatalf("restored capability admitted retired nonce, or negative did not reach attempt ownership: %+v", decision)
				}
				budgetLifecycleWant(t, tracker, 0)
			}
		})
	}
}
