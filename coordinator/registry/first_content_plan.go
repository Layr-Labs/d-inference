package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// firstContentPlanEntries retains the same bounded choices the initial
// selector would make after successively removing each winner. This keeps the
// 100-ms band, service load and affinity semantics out of a second comparator.
func firstContentPlanEntries(pool []*routingCandidate, winner *routingCandidate, affinity string) []planEntry {
	remaining := make([]*routingCandidate, 0, len(pool))
	for _, c := range pool {
		if c != winner {
			remaining = append(remaining, c)
		}
	}
	entries := make([]planEntry, 0, min(len(remaining), dispatchPlanMaxAlternates))
	for len(remaining) > 0 && len(entries) < dispatchPlanMaxAlternates {
		chosen, _, _, _ := selectRoutingCandidateWithAffinity(remaining, affinity)
		entries = append(entries, planEntry{provider: chosen.provider, view: planViewOf(chosen), evidenceQualified: chosen.firstContentEvidenceQualified, forecastAt: time.Now(), cacheEvidenceWeight: chosen.cacheEvidenceWeight, cacheEstimatedTTFTSavedMs: chosen.cacheEstimatedTTFTSavedMs, cacheAffinityEligible: chosen.cacheAffinityEligible})
		for i, c := range remaining {
			if c == chosen {
				remaining = append(remaining[:i], remaining[i+1:]...)
				break
			}
		}
	}
	return entries
}

func planViewOf(c *routingCandidate) PlanEntry {
	return PlanEntry{ProviderID: c.provider.ID, CostMs: c.costMs, FirstContent: c.firstContent, HealthMs: c.breakdown.HealthMs, CapacityRateMs: c.breakdown.CapacityRateMs,
		TTFTMs: c.firstContent.ExpectedMs, RawTTFTMs: c.breakdown.RawTTFTMs,
		StateMs: c.breakdown.StateMs, ModelLoaded: c.snapshot.modelLoaded,
		SlotState: c.snapshot.slotState, ChipFamily: c.snapshot.chipFamily}
}

// pendingEntries does not consume unchosen candidates. Primary retries and a
// hedge may race; claimEntry is the only transition that consumes an identity.
func (dp *DispatchPlan) pendingEntries() []planEntry {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return append([]planEntry(nil), dp.entries[dp.cursor:]...)
}

func (dp *DispatchPlan) claimEntry(id string) bool {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		if dp.entries[i].view.ProviderID != id {
			continue
		}
		dp.entries[dp.cursor], dp.entries[i] = dp.entries[i], dp.entries[dp.cursor]
		dp.cursor++
		dp.attempted[id] = struct{}{}
		return true
	}
	return false
}

// reserveFirstContentFromPlan re-ranks all surviving identities from CURRENT
// snapshots. Quotes are temporary evidence; final physical admission and cache
// proof validation still happen atomically in commitProviderReservation.
func (r *Registry) reserveFirstContentFromPlan(pr *PendingRequest, plan *DispatchPlan, excludeIDs ...string) (*Provider, RoutingDecision, []PlanSkip) {
	plan.reserveMu.Lock()
	defer plan.reserveMu.Unlock()
	model := plan.model
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}
	excluded := make(map[string]bool, len(excludeIDs)+len(pr.ExcludedProviderIDs))
	for _, id := range excludeIDs {
		excluded[id] = true
	}
	for _, id := range pr.ExcludedProviderIDs {
		excluded[id] = true
	}
	allowed := make(map[string]struct{}, len(pr.AllowedProviderSerials))
	for _, serial := range pr.AllowedProviderSerials {
		allowed[serial] = struct{}{}
	}
	var skips []PlanSkip
	for attempt := 0; attempt < maxReservationRescans && pr.RefreshFirstContentBudget(time.Now()); attempt++ {
		entries := plan.pendingEntries()
		if len(entries) == 0 {
			break
		}
		tracker, mode := r.prepareRequestCacheHints(model, pr)
		scan := providerReservationScan{cacheTracker: tracker, cacheMode: mode, claimPlanEntry: plan.claimEntry}
		views := make(map[string]PlanEntry, len(entries))
		r.mu.RLock()
		now := time.Now()
		for _, entry := range entries {
			id, p := entry.view.ProviderID, entry.provider
			reason := PlanSkipReason("")
			switch {
			case excluded[id]:
				reason = PlanSkipExcluded
			case r.providers[id] != p:
				reason = PlanSkipStaleSession
			}
			owned := false
			if reason == "" {
				owned = providerOwnedBy(p, pr.OwnerAccountID)
				if (pr.SelfRouteOnly && !owned) || !providerMatchesAllowedSerial(p, allowed) {
					reason = PlanSkipGateRejected
				}
			}
			var candidate *routingCandidate
			if reason == "" {
				p.mu.Lock()
				var snap routingSnapshot
				ok, _ := r.snapshotProviderIntoPLockedEx(&snap, p, model, pr.Traits, owned && (pr.PreferOwner || pr.SelfRouteOnly), false, now)
				if ok {
					candidate, _, ok = r.buildCandidateWithReason(snap, pr, now)
				}
				if ok && pr.RequiresVision {
					ok = r.providerServesVisionModelLocked(p, model, owned && (pr.PreferOwner || pr.SelfRouteOnly))
				}
				if ok {
					r.applyCacheRoutingCostPLocked(p, model, pr, candidate)
					r.estimateFirstContent(candidate, pr, now)
					applyFirstContentQuote(candidate, pr, entry.view, now)
					ok = firstContentCandidateAllowed(candidate, pr)
				}
				p.mu.Unlock()
				if !ok {
					reason = PlanSkipGateRejected
				}
			}
			if reason != "" {
				// A quote refresher or concurrent hedge can consume the identity first.
				// Record only the transition this caller actually owns.
				if plan.claimEntry(id) {
					skips = append(skips, PlanSkip{ProviderID: id, Reason: reason})
				}
				continue
			}
			scan.candidates.pool = append(scan.candidates.pool, candidate)
			views[id] = entry.view
		}
		pool := scan.candidates.pool
		var avoidedIDs []string
		if pr.Traits.AvoidVersion != "" {
			for _, c := range pool {
				if providerVersion(c.provider) == pr.Traits.AvoidVersion {
					avoidedIDs = append(avoidedIDs, c.provider.ID)
				}
			}
		}
		if pr.PreferOwner {
			pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return providerOwnedBy(c.provider, pr.OwnerAccountID) })
		}
		pool = preferFirstContentCandidates(pool)
		if pr.Traits.AvoidVersion != "" {
			pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return providerVersion(c.provider) != pr.Traits.AvoidVersion })
		}
		if pr.MinDecodeTPS > 0 {
			pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return projectedPerRequestDecodeTPS(&c.snapshot) >= pr.MinDecodeTPS })
		}
		scan.candidates.pool = pool
		scan.candidates.candidateCount = len(pool)
		affinity := ""
		if pr.CacheSelectionMode == "active" {
			affinity = pr.CachePlan.affinityKey
		}
		scan.selected, _, _, _ = selectRoutingCandidateWithAffinity(pool, affinity)
		if scan.selected != nil {
			view := views[scan.selected.provider.ID]
			scan.quote = &view
		}
		r.mu.RUnlock()
		if scan.selected == nil {
			break
		}
		// Do not consume an identity on a scan/commit race: current state may
		// reorder it behind another alternate during the bounded rescan.
		p, c, outcome, _ := r.commitProviderReservation(model, pr, scan, excludeIDs...)
		switch outcome {
		case reservationNeedsRescan:
			continue
		case reservationDeadlineExpired:
			return nil, RoutingDecision{Model: model}, skips
		case reservationCandidateRejected:
			plan.claimEntry(scan.selected.provider.ID)
			skips = append(skips, PlanSkip{ProviderID: scan.selected.provider.ID, Reason: PlanSkipGateRejected})
		case reservationCommitted:

			if pr.Traits.AvoidVersion != "" && providerVersion(p) != pr.Traits.AvoidVersion {
				for _, id := range avoidedIDs {
					if plan.claimEntry(id) {
						skips = append(skips, PlanSkip{ProviderID: id, Reason: PlanSkipVersionAvoided})
					}
				}
			}
			scan.candidates.promoteWinnerTop(c)
			return p, routingDecisionForCandidate(model, p, c, scan.candidates), skips
		}
	}
	skips = append(skips, PlanSkip{Reason: PlanSkipExhausted})
	return nil, RoutingDecision{Model: model}, skips
}

func applyFirstContentQuote(c *routingCandidate, pr *PendingRequest, quote PlanEntry, now time.Time) {
	if !quote.Confirmed || quote.Demoted || quote.QuoteConfidence != protocol.CapacityConfidenceHigh ||
		quote.QuoteObservedAt.IsZero() || now.Before(quote.QuoteObservedAt) || now.Sub(quote.QuoteObservedAt) > firstContentFreshness ||
		quote.QuoteCapacitySeq < c.snapshot.capacitySeq || c.snapshot.newestReservationAt.After(quote.QuoteObservedAt) ||
		(!pr.RequireFreshFeasibleAfter.IsZero() && !quote.QuoteObservedAt.After(pr.RequireFreshFeasibleAfter)) ||
		quote.QuoteTTFTP50 <= 0 || quote.QuoteTTFTP90 < quote.QuoteTTFTP50 ||
		(pr.FirstContentDeadline.IsZero() && (!(pr.Hedge || pr.RequireFreshFeasible) || pr.FirstContentPlanningHorizon <= 0)) ||
		firstContentForecastUnknownReason(&c.snapshot, pr, c.firstContent.PromptTokens, true) != "" {
		return
	}
	// The provider's quantiles have no sample-age or cache partition on the
	// wire. A fresh reply can confirm readiness, but cannot improve the local
	// qualified prediction or erase the current request's restore charge.
	c.firstContent.ExpectedMs = max(c.firstContent.ExpectedMs, float64(quote.QuoteTTFTP50)/float64(time.Millisecond)+c.firstContent.RestoreMs)
	c.firstContent.ConservativeMs = max(c.firstContent.ConservativeMs, float64(quote.QuoteTTFTP90)/float64(time.Millisecond)+c.firstContent.RestoreMs)
	if pr.FirstContentDeadline.IsZero() {
		c.firstContent.BudgetMs = float64(pr.FirstContentPlanningHorizon) / float64(time.Millisecond)
	} else {
		c.firstContent.BudgetMs = max(0, float64(pr.FirstContentDeadline.Sub(now))/float64(time.Millisecond))
	}
	c.firstContent.Status, c.firstContent.Reason = FirstContentFeasible, "fresh_quote"
	if c.firstContent.ConservativeMs > c.firstContent.BudgetMs {
		c.firstContent.Status = FirstContentPredictedLate
	}
}
