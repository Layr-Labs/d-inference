package registry

import (
	"testing"
	"time"
)

func TestAccountAffinityPlanResumesHRWAfterPriorityTierLosesCapacity(t *testing.T) {
	for _, preference := range []string{"owner", "version", "negative_quote", "owner_and_version"} {
		t.Run(preference, func(t *testing.T) {
			r, providers := accountAffinityPlanFixture(t, 4)
			pr := routingAffinityRequest("tier-primary")
			if preference == "owner" || preference == "owner_and_version" {
				pr.PreferOwner, pr.OwnerAccountID = true, pr.ConsumerKey
				for _, p := range providers {
					p.mu.Lock()
					p.AccountID = pr.ConsumerKey
					p.mu.Unlock()
				}
			}
			order := accountAffinityPlanOrder(providers, pr)
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary != order[0] || plan == nil || plan.Len() != 3 {
				t.Fatal("missing affinity plan")
			}
			primary.RemovePending(pr.RequestID)
			retry := routingAffinityRequest("tier-retry")
			retry.PreferOwner, retry.OwnerAccountID = pr.PreferOwner, pr.OwnerAccountID
			if preference == "version" || preference == "owner_and_version" {
				retry.Traits.AvoidVersion = "avoid-build"
			}
			// Leave exactly one higher-priority alternate. In the lower tier,
			// HRW prefers the idle ~900ms machine over the idle ~400ms one.
			for i, p := range order[2:] {
				p.mu.Lock()
				p.PrefillTPS = []float64{112.35955056, 256.41025641}[i]
				if retry.PreferOwner {
					p.AccountID = "different-owner"
				}
				if retry.Traits.AvoidVersion != "" {
					p.Version = retry.Traits.AvoidVersion
				}
				p.mu.Unlock()
				if preference == "negative_quote" {
					plan.DemoteEntry(p.ID)
				}
			}
			var skips []PlanSkip
			var attempts []*Provider
			r.mu.RLock()
			got, decision, _ := r.reserveAccountAffinityPlan(retry, plan, nil, nil,
				func(entry planEntry, guard *accountAffinityPlanGuard) (*Provider, RoutingDecision, bool) {
					p := entry.provider
					attempts = append(attempts, p)
					p.mu.Lock()
					defer p.mu.Unlock()
					if p == order[1] {
						// Another request filled the sole preferred-tier machine
						// after the shortlist snapshot, before the atomic debit.
						p.BackendCapacity.Slots[0].NumRunning = p.BackendCapacity.Slots[0].MaxConcurrency
					}
					now := time.Now()
					var snap routingSnapshot
					if ok, _ := r.snapshotProviderIntoPLockedEx(&snap, p, retry.Model, retry.Traits, false, false, now); !ok {
						return nil, RoutingDecision{}, false
					}
					candidate, _, ok := r.buildCandidateWithReason(snap, retry, now)
					if !ok || !guard.admits(entry, candidate, retry) || !r.providerCanAdmitLockedEx(p, retry.Model, retry.Traits, false, false, now) {
						return nil, RoutingDecision{}, false
					}
					retry.ProviderID = p.ID
					p.addPendingLocked(retry)
					return p, RoutingDecision{ProviderID: p.ID, TTFTMs: candidate.breakdown.TTFTMs}, true
				}, &skips)
			r.mu.RUnlock()
			if got != nil {
				got.RemovePending(retry.RequestID)
			}
			if got != order[2] || !decision.AccountAffinity.Applied || len(attempts) != 2 || attempts[0] != order[1] {
				t.Fatalf("lower tier lost HRW ordering: got=%s want=%s attempts=%d observation=%+v", decision.ProviderID, order[2].ID, len(attempts), decision.AccountAffinity)
			}
			if decision.AccountAffinity.CandidateCount != 2 || decision.AccountAffinity.Rank != 1 || decision.AccountAffinity.AddedTTFTMs != 0 {
				t.Fatalf("lower-tier observation did not describe its live affinity pool: %+v", decision.AccountAffinity)
			}
			if order[1].PendingCount() != 0 || order[3].PendingCount() != 0 {
				t.Fatal("failed or skipped candidates retained a reservation")
			}
		})
	}
}
