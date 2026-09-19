package registry

import (
	"sort"
	"time"
)

type accountAffinityPlanCandidate struct {
	entry     planEntry
	candidate *routingCandidate
	owned     bool
}

type accountAffinityPlanReserve func(planEntry, *accountAffinityPlanGuard) (*Provider, RoutingDecision, bool)

// reserveAccountAffinityPlan reads at most eight retained identities once, then
// applies the same soft policy as primary selection. It never rescans the fleet
// or waits for a preferred provider. r's commit lock is already held; the final
// reserve callback repeats all gates and the busy bound under the debit's p.mu.
func (r *Registry) reserveAccountAffinityPlan(pr *PendingRequest, plan *DispatchPlan,
	exclude, allowedSerials map[string]struct{}, reserve accountAffinityPlanReserve, skips *[]PlanSkip,
) (*Provider, RoutingDecision, []PlanSkip) {
	live := r.accountAffinityPlanCandidates(pr, plan, exclude, allowedSerials, skips)
	_, observation := evaluateAccountAffinity(nil, pr, r.accountAffinity)
	// Version diversity and owned-machine preference outrank affinity, just as
	// in the full scan. Negative quotes remain a last-resort tier. Affirmative
	// quote arrival order cannot promote a lower-HRW alternate.
	tier := func(item accountAffinityPlanCandidate) int {
		value := 0
		if pr.PreferOwner && !item.owned {
			value += 4
		}
		if avoid := pr.Traits.AvoidVersion; avoid != "" && item.candidate.snapshot.binaryVersion == avoid {
			value += 2
		}
		if item.entry.view.Demoted {
			value++
		}
		return value
	}
	legacyBefore := func(a, b accountAffinityPlanCandidate) bool {
		if tier(a) != tier(b) {
			return tier(a) < tier(b)
		}
		if planEntryRank(a.entry.view) != planEntryRank(b.entry.view) {
			return planEntryRank(a.entry.view) < planEntryRank(b.entry.view)
		}
		return a.candidate.costMs < b.candidate.costMs
	}
	sort.SliceStable(live, func(i, j int) bool { return legacyBefore(live[i], live[j]) })
	// Exhaust the affinity and ordinary-cost options WITHIN a preference tier
	// before considering weaker owner/version/negative-quote alternatives. A
	// busy affinity owner must not turn an otherwise free owned route into a
	// public paid route, nor defeat a healthy-version retry preference.
	for start := 0; start < len(live); {
		end := start + 1
		for end < len(live) && tier(live[end]) == tier(live[start]) {
			end++
		}
		// Evaluate EACH reachable tier, not just the initially preferred pool.
		// If its last provider loses a hard gate at the final debit, the next
		// tier must still use HRW rather than silently falling back to speed.
		current := live[start:end]
		baseline := current[0].entry.view.ProviderID // already legacy-cost sorted
		var candidates [dispatchPlanMaxAlternates]*routingCandidate
		pool := candidates[:len(current)]
		for i, item := range current {
			pool[i] = item.candidate
		}
		_, observation = evaluateAccountAffinity(pool, pr, r.accountAffinity)
		sort.SliceStable(current, func(i, j int) bool {
			a, b := current[i], current[j]
			if a.candidate.accountAffinityEligible != b.candidate.accountAffinityEligible {
				return a.candidate.accountAffinityEligible
			}
			if a.candidate.accountAffinityEligible {
				return accountAffinityCandidateBefore(a.candidate, b.candidate)
			}
			return legacyBefore(a, b)
		})
		finish := func(p *Provider, decision RoutingDecision, item accountAffinityPlanCandidate, guard *accountAffinityPlanGuard) (*Provider, RoutingDecision, []PlanSkip) {
			decision = accountAffinityPlanDecision(decision, item, guard, pool, baseline, observation)
			return p, decision, *skips
		}
		type fallbackEntry struct {
			item    accountAffinityPlanCandidate
			claimed bool
		}
		var fallback []fallbackEntry
		for _, item := range current {
			if !item.candidate.accountAffinityEligible {
				fallback = append(fallback, fallbackEntry{item: item})
				continue
			}
			entry, ok := plan.claimEntry(item.entry.view.ProviderID)
			if !ok {
				continue // another retry/hedge already consumed this alternate
			}
			guard := &accountAffinityPlanGuard{config: r.accountAffinity, prefer: true}
			if p, decision, ok := reserve(entry, guard); ok {
				return finish(p, decision, item, guard)
			}
			if guard.softRejected {
				fallback = append(fallback, fallbackEntry{item: item, claimed: true})
			}
		}
		// Affinity is not admission: final busy/latency races fall back to
		// legacy cost with full hard gates, never to a new wait or rejection.
		sort.SliceStable(fallback, func(i, j int) bool { return legacyBefore(fallback[i].item, fallback[j].item) })
		for _, candidate := range fallback {
			item := candidate.item
			if !candidate.claimed {
				entry, ok := plan.claimEntry(item.entry.view.ProviderID)
				if !ok {
					continue
				}
				item.entry = entry
			}
			guard := &accountAffinityPlanGuard{config: r.accountAffinity}
			if p, decision, ok := reserve(item.entry, guard); ok {
				return finish(p, decision, item, guard)
			}
		}
		start = end
	}
	*skips = append(*skips, PlanSkip{Reason: PlanSkipExhausted})
	return nil, RoutingDecision{Model: plan.model, AccountAffinity: observation}, *skips
}

// Retry observations describe the tier actually used, including its cost
// baseline and HRW rank. A failed higher tier must not leave stale diagnostics.
func accountAffinityPlanDecision(decision RoutingDecision, item accountAffinityPlanCandidate, guard *accountAffinityPlanGuard,
	pool []*routingCandidate, baseline string, observation AccountAffinityObservation,
) RoutingDecision {
	observation.Applied = guard.prefer
	observation.WouldChange = guard.prefer && item.entry.view.ProviderID != baseline
	observation.Rank, observation.AddedTTFTMs = 0, 0
	if guard.prefer {
		decision.SelectionPath = SelectionAccountAffinity
		observation.Rank = 1
		for _, candidate := range pool {
			if candidate.accountAffinityRanked && accountAffinityCandidateBefore(candidate, item.candidate) {
				observation.Rank++
			}
		}
		observation.AddedTTFTMs = guard.checkedLoadDelayMs
		observation.Reason = "preferred"
		if observation.Rank > 1 {
			observation.Reason = "spill"
		}
	} else if observation.Evaluated {
		observation.Reason = "plan_fallback"
	}
	decision.AccountAffinity = observation
	return decision
}

func (r *Registry) accountAffinityPlanCandidates(pr *PendingRequest, plan *DispatchPlan,
	exclude, allowedSerials map[string]struct{}, skips *[]PlanSkip,
) []accountAffinityPlanCandidate {
	entries := plan.remainingEntries()
	live := make([]accountAffinityPlanCandidate, 0, len(entries))
	for _, entry := range entries {
		id, p := entry.view.ProviderID, entry.provider
		reason := PlanSkipReason("")
		if _, excluded := exclude[id]; excluded {
			reason = PlanSkipExcluded
		} else if r.providers[id] != p {
			reason = PlanSkipStaleSession
		}
		owned := false
		if reason == "" {
			owned = providerOwnedBy(p, pr.OwnerAccountID)
			if (pr.SelfRouteOnly && !owned) || (len(allowedSerials) > 0 && !providerMatchesAllowedSerial(p, allowedSerials)) {
				reason = PlanSkipGateRejected
			}
		}
		if reason == "" {
			now := time.Now()
			var snap routingSnapshot
			ok, _ := r.snapshotProviderIntoLockedEx(&snap, p, plan.model, pr.Traits,
				owned && (pr.SelfRouteOnly || pr.PreferOwner), false, now)
			if ok && snap.affinityIdentity == entry.affinityIdentity {
				candidate, _, valid := r.buildCandidateWithReason(snap, pr, now)
				if valid && (pr.MaxTTFTMs <= 0 || !snap.hasBackendCapacity || candidate.breakdown.TTFTMs <= pr.MaxTTFTMs) {
					live = append(live, accountAffinityPlanCandidate{entry: entry, candidate: candidate, owned: owned})
					continue
				}
			}
			reason = PlanSkipGateRejected
		}
		if _, claimed := plan.claimEntry(id); claimed {
			*skips = append(*skips, PlanSkip{ProviderID: id, Reason: reason})
		}
	}
	return live
}
