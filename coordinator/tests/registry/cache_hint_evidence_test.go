package registry_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestReservationRefreshesInvalidatedHolderEvidence(t *testing.T) {
	for _, outcome := range []string{"miss_absent", "miss_corrupt", "shorter_hit"} {
		t.Run(outcome, func(t *testing.T) {
			var planner *production.ReservationPlanner
			f := newShorterHitFixture(t, production.Dependencies{
				Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
					planner = actual
					return actual
				},
			})
			f.donate(t, f.p, "donor-p", 1, "ssd", f.plan, f.short, f.long)
			f.donate(t, f.q, "donor-q", 1, "ssd", f.plan, f.short)
			request := &production.PendingRequest{RequestID: "reservation", Model: "model", CachePlan: f.plan,
				EstimatedPromptTokens: f.plan.PromptTokenCount, RequestedMaxTokens: 128}
			selection := planner.Prepare("model", request).Finish()
			if selection.Provider != f.p {
				t.Fatal("positive control: the deeper holder must win preparation")
			}
			if outcome == "shorter_hit" {
				if got := f.hit(t, f.p, "intervening", 3, "ssd", f.plan, f.short); !got.Accepted {
					t.Fatalf("shorter hit = %+v", got)
				}
			} else {
				lookup := fenceTestV2Lookup(f.attempt(t, f.p, "intervening", f.plan), f.capability,
					f.plan.Boundaries[len(f.plan.Boundaries)-1], 3)
				lookup.RequestID, lookup.Outcome = "intervening", outcome
				if got := f.r.ApplyPrefixCacheLookupV2Result(f.p.ID, lookup); !got.Accepted {
					t.Fatalf("miss = %+v", got)
				}
			}
			if f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.q, f.plan, f.short, "ssd") {
				t.Fatal("receipt did not remove only the affected provider's deeper evidence")
			}
			if got := selection.Commit("model", request); got.Provider != nil || got.Outcome != production.ReservationNeedsRescan {
				t.Fatalf("stale prepared holder committed: reserved=%t outcome=%v", got.Provider != nil, got.Outcome)
			}
			if f.p.PendingCount() != 0 || request.CacheSelectionSelected {
				t.Fatal("stale commit debited capacity or published cache credit")
			}
			selected, decision, refreshed := f.reserve(t, "refreshed")
			if selected == f.p && outcome != "shorter_hit" {
				t.Fatal("fresh reservation preferred the absent holder")
			}
			if decision.CacheEstimatedTTFTSavedMs <= 0 || decision.CacheEstimatedTTFTSavedMs > 1998 ||
				!refreshed.CacheSelectionSelected {
				t.Fatalf("fresh reservation did not use surviving shorter evidence: %+v", decision)
			}
			if status := f.r.CacheRoutingLifecycleStatus(); status.FencesApplied != 0 {
				t.Fatal("ordinary cache evidence loss quarantined the capability")
			}
			if f.p.PrefixCacheV2Models["model"].CacheEpoch != f.capability.CacheEpoch {
				t.Fatal("evidence loss rotated the persistent epoch")
			}
		})
	}
}

func TestShorterHitPreservesUnchangedHintEvidence(t *testing.T) {
	var planner *production.ReservationPlanner
	f := newShorterHitFixture(t, production.Dependencies{
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
	})
	earlier := exactTestAnchor(4, "b")
	f.plan = f.pricing.plans.bind(exactTestPlan(earlier, f.short, f.long, exactTestAnchor(17, "e")))
	f.donate(t, f.p, "donor-p", 1, "ssd", f.plan, earlier, f.short, f.long)
	f.donate(t, f.q, "donor-q", 1, "ssd", f.plan, f.long)
	shortPlan := f.pricing.plans.bind(exactTestPlan(earlier))
	shortHint := f.pricing.hints(shortPlan, time.Now())[f.p.ID]
	otherHint := f.pricing.hints(f.plan, time.Now())[f.q.ID]
	deepHint := f.pricing.hints(f.plan, time.Now())[f.p.ID]
	request := &production.PendingRequest{RequestID: "unaffected-reservation", Model: "model", CachePlan: shortPlan,
		EstimatedPromptTokens: shortPlan.PromptTokenCount, RequestedMaxTokens: 128}
	selection := planner.Prepare("model", request).Finish()
	if selection.Provider != f.p {
		t.Fatal("positive control: P must hold the earlier endpoint")
	}
	// A hit at an already-held short endpoint refreshes that record as well as
	// removing the deeper one. A still-shorter endpoint is unaffected.
	nonce := f.attempt(t, f.p, "intervening", f.plan)
	if got := f.lookup(t, f.p, "intervening", nonce, 3, "ssd", f.plan, &f.short); !got.Accepted {
		t.Fatalf("shorter hit = %+v", got)
	}
	f.p.Mu().Lock()
	deepCurrent := deepHint.CurrentForProviderLocked(f.p, "model")
	f.p.Mu().Unlock()
	if deepCurrent {
		t.Fatal("removed deeper evidence still validates")
	}
	f.q.Mu().Lock()
	otherCurrent := otherHint.CurrentForProviderLocked(f.q, "model")
	f.q.Mu().Unlock()
	if !otherCurrent {
		t.Fatal("another provider's surviving evidence was invalidated")
	}
	f.p.Mu().Lock()
	shortCurrent := shortHint.CurrentForProviderLocked(f.p, "model")
	f.p.Mu().Unlock()
	if !shortCurrent || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("shorter hit invalidated unrelated surviving shorter evidence")
	}
	if got := selection.Commit("model", request); got.Provider != f.p || got.Outcome != production.ReservationCommitted ||
		!request.CacheSelectionSelected {
		t.Fatalf("unaffected prepared endpoint did not commit: reserved=%t outcome=%v", got.Provider != nil, got.Outcome)
	}
	f.p.RemovePending(request.RequestID)
	f.r.SetProviderIdle(f.p.ID)
	// Re-teaching the removed endpoint must not revive a copy of its old proof.
	f.ready(t, f.p, "intervening", nonce, 4, "ssd", f.long)
	f.p.Mu().Lock()
	oldCurrent := deepHint.CurrentForProviderLocked(f.p, "model")
	f.p.Mu().Unlock()
	if oldCurrent || f.pricing.hints(f.plan, time.Now())[f.p.ID].CachedTokens != f.long.TokenCount {
		t.Fatal("re-teaching failed or revived the revoked proof")
	}
}

func TestHolderRefreshRetiresOnlyReplacedObservation(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
	old := f.pricing.hints(f.plan, time.Now())[f.p.ID]
	// A replay is rejected before mutating holder evidence.
	if got := f.hit(t, f.p, "replayed", 2, "ssd", f.plan, f.long); got.Reason != production.CacheReceiptSequence {
		t.Fatalf("replayed hit = %+v", got)
	}
	f.p.Mu().Lock()
	current := old.CurrentForProviderLocked(f.p, "model")
	f.p.Mu().Unlock()
	if !current {
		t.Fatal("a rejected receipt invalidated the holder observation")
	}
	if got := f.hit(t, f.p, "refresh", 3, "ssd", f.plan, f.long); !got.Accepted {
		t.Fatalf("refresh = %+v", got)
	}
	fresh := f.pricing.hints(f.plan, time.Now())[f.p.ID]
	f.p.Mu().Lock()
	oldCurrent := old.CurrentForProviderLocked(f.p, "model")
	freshCurrent := fresh.CurrentForProviderLocked(f.p, "model")
	f.p.Mu().Unlock()
	if oldCurrent || !freshCurrent || fresh.StageMs != 50 || old.StageMs != 100 {
		t.Fatal("refresh did not retire the old price and publish the new observation")
	}
	if !f.holds(f.p, f.plan, f.short, "ssd") || !f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("refresh removed surviving endpoints")
	}
}
