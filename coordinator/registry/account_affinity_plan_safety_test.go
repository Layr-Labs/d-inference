package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAccountAffinityPlanScopeAndConfigurationFences(t *testing.T) {
	for _, change := range []string{"account", "off", "shadow", "premium", "model", "identity", "expired"} {
		t.Run(change, func(t *testing.T) {
			r, _ := accountAffinityPlanFixture(t, 3)
			pr := routingAffinityRequest("fence-primary")
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary == nil || plan == nil || plan.Len() != 2 {
				t.Fatal("missing plan")
			}
			primary.RemovePending(pr.RequestID)
			first, second := plan.entries[0].provider, plan.entries[1].provider
			// Establish a unique retained legacy cost order opposite to HRW so
			// the fence test cannot accidentally pass when the old rank survives.
			plan.entries[0].view.CostMs = 20_000
			plan.entries[1].view.CostMs = 1
			retry := routingAffinityRequest("fence-retry")
			switch change {
			case "account":
				retry.ConsumerKey = "different-authenticated-account"
			case "off", "shadow":
				if err := r.ConfigureAccountAffinity(AccountAffinityConfig{Mode: change, MaxTTFTPenaltyMs: 250}); err != nil {
					t.Fatal(err)
				}
			case "premium":
				if err := r.ConfigureAccountAffinity(AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 10}); err != nil {
					t.Fatal(err)
				}
			case "model":
				retry.Model = "a-different-concrete-build"
			case "identity":
				first.mu.Lock()
				first.AttestationResult.SerialNumber = "a-different-physical-machine"
				first.mu.Unlock()
			case "expired":
				retry.FirstContentDeadline = time.Now().Add(-time.Millisecond)
			}
			got, d, _ := r.ReserveNextFromPlan(retry, plan)
			if change == "model" || change == "expired" {
				if got != nil || first.PendingCount()+second.PendingCount() != 0 {
					t.Fatal("scope/deadline fence leaked a reservation")
				}
				if change == "model" {
					if got, _, _, performed := r.RefreshDispatchPlan(retry, plan); got != nil || performed || plan.RefreshUsed() {
						t.Fatal("mismatched-model refresh scanned or reserved another build")
					}
				}
				return
			}
			if got != second {
				t.Fatalf("%s retained stale affinity: got=%v want=%s", change, got, second.ID)
			}
			if change != "identity" && d.AccountAffinity.Applied {
				t.Fatal("scope/configuration fallback still claims affinity")
			}
			got.RemovePending(retry.RequestID)
		})
	}
}

func TestAccountAffinityPlanOffAndShadowRetainLegacyQuoteOrder(t *testing.T) {
	for _, mode := range []string{AccountAffinityOff, AccountAffinityShadow} {
		t.Run(mode, func(t *testing.T) {
			r, _ := routingAffinityFixture(t, mode)
			pr := routingAffinityRequest("legacy-quotes")
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary == nil || plan == nil || plan.affinity.enabled {
				t.Fatal("off/shadow enabled affinity plan order")
			}
			primary.RemovePending(pr.RequestID)
			second := plan.entries[1].view.ProviderID
			plan.ConfirmEntry(second, &protocol.CapacityQuoteMessage{TTFTP90MS: 100})
			if next, _ := plan.PeekNext(); next.ProviderID != second {
				t.Fatal("off/shadow changed affirmative-quote promotion")
			}
		})
	}
}

func TestAccountAffinityPlanInitialFallbackRetainsLegacyOrder(t *testing.T) {
	r, providers := accountAffinityPlanFixture(t, 3)
	for _, p := range providers {
		p.mu.Lock()
		p.AttestationResult.Valid = false // routable, but no verified affinity identity
		p.mu.Unlock()
	}
	pr := routingAffinityRequest("unavailable-affinity")
	primary, d, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary == nil || plan == nil || d.AccountAffinity.Applied || plan.affinity.enabled {
		t.Fatal("initial legacy fallback retained an affinity-ordered plan")
	}
	primary.RemovePending(pr.RequestID)
	second := plan.entries[1].view.ProviderID
	plan.ConfirmEntry(second, &protocol.CapacityQuoteMessage{TTFTP90MS: 100})
	if next, _ := plan.PeekNext(); next.ProviderID != second {
		t.Fatal("no-affinity fallback changed legacy quote order")
	}
}

func TestAccountAffinityPlanVersionDiversityRemainsSoft(t *testing.T) {
	for _, allAvoided := range []bool{false, true} {
		t.Run(map[bool]string{false: "diverse", true: "all_avoided"}[allAvoided], func(t *testing.T) {
			r, _ := accountAffinityPlanFixture(t, 3)
			pr := routingAffinityRequest("version-primary")
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary == nil || plan == nil || plan.Len() != 2 {
				t.Fatal("missing plan")
			}
			primary.RemovePending(pr.RequestID)
			first, second := plan.entries[0].provider, plan.entries[1].provider
			first.mu.Lock()
			first.Version = "bad-build"
			first.mu.Unlock()
			second.mu.Lock()
			second.Version = "healthy-build"
			if allAvoided {
				second.Version = "bad-build"
			}
			second.mu.Unlock()
			retry := routingAffinityRequest("version-retry")
			retry.Traits.AvoidVersion = "bad-build"
			got, _, _ := r.ReserveNextFromPlan(retry, plan)
			want := second
			if allAvoided {
				want = first
			}
			if got != want {
				t.Fatalf("version preference bypassed or failed closed: got=%v want=%s", got, want.ID)
			}
			got.RemovePending(retry.RequestID)
		})
	}
}

func TestAccountAffinityPlanRechecksOwnerConstraints(t *testing.T) {
	for _, exclusive := range []bool{false, true} {
		t.Run(map[bool]string{false: "prefer_owner", true: "exclusive_owner"}[exclusive], func(t *testing.T) {
			r, providers := accountAffinityPlanFixture(t, 3)
			pr := routingAffinityRequest("owned-primary")
			pr.OwnerAccountID = pr.ConsumerKey
			pr.PreferOwner, pr.SelfRouteOnly = !exclusive, exclusive
			for _, p := range providers {
				p.mu.Lock()
				p.AccountID = pr.ConsumerKey
				p.mu.Unlock()
			}
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary == nil || plan == nil || plan.Len() != 2 {
				t.Fatal("missing owned plan")
			}
			primary.RemovePending(pr.RequestID)
			first, second := plan.entries[0].provider, plan.entries[1].provider
			first.mu.Lock()
			first.AccountID = "a-different-owner"
			first.mu.Unlock()
			retry := routingAffinityRequest("owned-retry")
			retry.OwnerAccountID, retry.PreferOwner, retry.SelfRouteOnly = pr.OwnerAccountID, pr.PreferOwner, pr.SelfRouteOnly
			got, _, _ := r.ReserveNextFromPlan(retry, plan)
			if got != second || first.PendingCount() != 0 {
				t.Fatal("account affinity bypassed the live owner preference/constraint")
			}
			got.RemovePending(retry.RequestID)
		})
	}
}

func TestAccountAffinityPlanAtomicGuardAndSoftFallback(t *testing.T) {
	r, _ := accountAffinityPlanFixture(t, 3)
	pr := routingAffinityRequest("atomic-primary")
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary == nil || plan == nil {
		t.Fatal("missing plan")
	}
	primary.RemovePending(pr.RequestID)
	retry := routingAffinityRequest("atomic-retry")
	// Exercise the same final guard used while p.mu is held by the production
	// debit callback. Deliberately degrade every preferred candidate after the
	// live bounded snapshot but before final reservation; only the optional
	// affinity preference should fail, not the whole request.
	var skips []PlanSkip
	preferredChecks, fallbackChecks := 0, 0
	r.mu.RLock()
	got, d, _ := r.reserveAccountAffinityPlan(retry, plan, nil, nil,
		func(entry planEntry, guard *accountAffinityPlanGuard) (*Provider, RoutingDecision, bool) {
			p := entry.provider
			p.mu.Lock()
			defer p.mu.Unlock()
			if guard.prefer {
				preferredChecks++
				p.BackendCapacity.Slots[0].NumWaiting = 3
			} else {
				fallbackChecks++
			}
			var snap routingSnapshot
			if ok, _ := r.snapshotProviderIntoPLockedEx(&snap, p, retry.Model, retry.Traits, false, false, time.Now()); !ok {
				t.Fatal("fixture lost hard eligibility")
			}
			c, _, ok := r.buildCandidateWithReason(snap, retry, time.Now())
			if !ok {
				t.Fatal("fixture lost hard capacity")
			}
			if !guard.admits(entry, c, retry) {
				return nil, RoutingDecision{}, false
			}
			retry.ProviderID = p.ID
			p.addPendingLocked(retry)
			return p, RoutingDecision{ProviderID: p.ID, TTFTMs: c.breakdown.TTFTMs}, true
		}, &skips)
	r.mu.RUnlock()
	if got == nil || preferredChecks != 2 || fallbackChecks != 1 || d.AccountAffinity.Applied || d.AccountAffinity.Reason != "plan_fallback" {
		t.Fatalf("affinity recheck failed closed: got=%v preferred=%d fallback=%d observation=%+v", got, preferredChecks, fallbackChecks, d.AccountAffinity)
	}
	got.RemovePending(retry.RequestID)
}

func TestAccountAffinityPlanTelemetryUsesFinalCheckedLoad(t *testing.T) {
	r, _ := accountAffinityPlanFixture(t, 3)
	pr := routingAffinityRequest("load-telemetry-primary")
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary == nil || plan == nil {
		t.Fatal("missing plan")
	}
	primary.RemovePending(pr.RequestID)
	retry := routingAffinityRequest("load-telemetry-retry")
	var skips []PlanSkip
	checkedDelay := 0.0
	r.mu.RLock()
	got, decision, _ := r.reserveAccountAffinityPlan(retry, plan, nil, nil,
		func(entry planEntry, guard *accountAffinityPlanGuard) (*Provider, RoutingDecision, bool) {
			p := entry.provider
			p.mu.Lock()
			defer p.mu.Unlock()
			// The shortlist snapshot was idle. Add a tolerable real queue delay
			// only now, inside the final debit lock, and verify its new value is
			// what the plan emits rather than the old zero-load observation.
			p.BackendCapacity.Slots[0].NumWaiting = 1
			var snap routingSnapshot
			if ok, _ := r.snapshotProviderIntoPLockedEx(&snap, p, retry.Model, retry.Traits, false, false, time.Now()); !ok {
				t.Fatal("fixture lost eligibility")
			}
			candidate, _, ok := r.buildCandidateWithReason(snap, retry, time.Now())
			if !ok || !guard.admits(entry, candidate, retry) || !guard.prefer {
				t.Fatal("tolerable same-machine load unexpectedly rejected affinity")
			}
			checkedDelay = accountAffinityLoadDelayMs(candidate)
			retry.ProviderID = p.ID
			p.addPendingLocked(retry)
			return p, RoutingDecision{ProviderID: p.ID, TTFTMs: candidate.breakdown.TTFTMs}, true
		}, &skips)
	r.mu.RUnlock()
	if got == nil || !decision.AccountAffinity.Applied || checkedDelay <= 0 ||
		checkedDelay > 250 || decision.AccountAffinity.AddedTTFTMs != checkedDelay {
		t.Fatalf("plan emitted stale or cross-machine load telemetry: checked=%f observation=%+v", checkedDelay, decision.AccountAffinity)
	}
	got.RemovePending(retry.RequestID)
}

func TestAccountAffinityPlanSoftFallbackPreservesHigherPriorityTier(t *testing.T) {
	for _, preference := range []string{"owner", "version", "negative_quote"} {
		t.Run(preference, func(t *testing.T) {
			r, providers := accountAffinityPlanFixture(t, 3)
			pr := routingAffinityRequest("priority-primary")
			if preference == "owner" {
				pr.PreferOwner, pr.OwnerAccountID = true, pr.ConsumerKey
				for _, p := range providers {
					p.mu.Lock()
					p.AccountID = pr.ConsumerKey
					p.mu.Unlock()
				}
			}
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary == nil || plan == nil || plan.Len() != 2 {
				t.Fatal("missing plan")
			}
			primary.RemovePending(pr.RequestID)
			first, second := plan.entries[0].provider, plan.entries[1].provider
			retry := routingAffinityRequest("priority-retry")
			retry.PreferOwner, retry.OwnerAccountID = pr.PreferOwner, pr.OwnerAccountID
			switch preference {
			case "owner":
				second.mu.Lock()
				second.AccountID = "different-owner"
				second.mu.Unlock()
			case "version":
				second.mu.Lock()
				second.Version = "avoid-build"
				second.mu.Unlock()
				retry.Traits.AvoidVersion = "avoid-build"
			case "negative_quote":
				plan.DemoteEntry(second.ID)
			}
			var skips []PlanSkip
			calls := 0
			r.mu.RLock()
			got, d, _ := r.reserveAccountAffinityPlan(retry, plan, nil, nil,
				func(entry planEntry, guard *accountAffinityPlanGuard) (*Provider, RoutingDecision, bool) {
					calls++
					if entry.provider != first {
						t.Error("optional affinity skipped a still-admissible higher-priority tier")
					}
					if guard.prefer {
						guard.softRejected = true // final busy recheck, not hard admission
						return nil, RoutingDecision{}, false
					}
					return entry.provider, RoutingDecision{ProviderID: entry.provider.ID}, true
				}, &skips)
			r.mu.RUnlock()
			if got != first || calls != 2 || d.AccountAffinity.Applied {
				t.Fatal("legacy fallback must precede weaker preference tiers")
			}
		})
	}
}
