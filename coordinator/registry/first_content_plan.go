package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/shortlist"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

// firstContentPlanEntries retains the same bounded choices the initial
// selector would make after successively removing each winner. This keeps the
// 100-ms band, service load and affinity semantics out of a second comparator.
func firstContentPlanEntries(pool []*routingCandidate, winner *routingCandidate, affinity string) []planEntry {
	return selection.Retain(pool, winner, dispatchPlanMaxAlternates, func(remaining []*routingCandidate) *routingCandidate {
		chosen, _, _, _ := selectRoutingCandidateWithAffinity(remaining, affinity)
		return chosen
	}, func(chosen *routingCandidate) planEntry {
		return planEntry{PlanEntry: planViewOf(chosen), EvidenceQualified: chosen.firstContentEvidenceQualified, ForecastAt: time.Now(), CacheEvidenceWeight: chosen.cacheEvidenceWeight, CacheEstimatedTTFTSavedMs: chosen.cacheEstimatedTTFTSavedMs, CacheAffinityEligible: chosen.cacheAffinityEligible}
	})
}

func planViewOf(c *routingCandidate) PlanEntry {
	return c.Quote()
}

// Quote captures the identity and forecast used to assemble a retained plan.
// Reservation always revalidates the session and admission state before debit.
func (c *Candidate) Quote() PlanEntry {
	return PlanEntry{CandidateBinding: c.snapshot.CandidateBinding, ProviderID: c.provider.ID, CostMs: c.costMs, FirstContent: c.firstContent, HealthMs: c.breakdown.HealthMs, CapacityRateMs: c.breakdown.CapacityRateMs,
		TTFTMs: c.firstContent.ExpectedMs, RawTTFTMs: c.breakdown.RawTTFTMs,
		StateMs: c.breakdown.StateMs, ModelLoaded: c.snapshot.modelLoaded,
		SlotState: c.snapshot.slotState, ChipFamily: c.snapshot.chipFamily}
}

// pendingEntries does not consume unchosen candidates. Primary retries and a
// hedge may race; claimEntry is the only transition that consumes an identity.
func (dp *QuotePlan) pendingEntries() []planEntry {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return dp.pendingEntriesLocked()
}

func (dp *QuotePlan) pendingEntriesLocked() []planEntry {
	entries := make([]planEntry, 0, dp.alternates().Remaining())
	dp.alternates().Range(func(handle shortlist.Handle) bool {
		entries = append(entries, dp.entries[handle.Index])
		return true
	})
	return entries
}

func (dp *DispatchPlan) claimEntry(id string) bool {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.alternates().Claim(id) {
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
			id, p := entry.ProviderID, entry.provider
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
					applyFirstContentQuote(candidate, pr, entry.PlanEntry, now)
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
			scan.candidates.Candidates = append(scan.candidates.Candidates, candidate)
			views[id] = entry.PlanEntry
		}
		pool := scan.candidates.Candidates
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
		scan.candidates.Candidates = pool
		scan.candidates.CandidateCount = len(pool)
		affinity := ""
		if pr.CacheSelectionMode == "active" {
			affinity = pr.CachePlan.AffinityKey()
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
	c.firstContent = forecast.ApplyQuote(forecast.Result{Estimate: c.firstContent, Calibrated: c.snapshot.calibratedForecastQualified},
		firstContentForecastEvidence(&c.snapshot, c.firstContent.PromptTokens),
		forecast.Request{PromptTokens: c.firstContent.PromptTokens, FreshAfter: pr.RequireFreshFeasibleAfter,
			Incoming: performance.IncomingWork{RequiresVision: pr.RequiresVision}, Deadline: pr.FirstContentDeadline,
			Hedge: pr.Hedge, RequireFreshFeasible: pr.RequireFreshFeasible, PlanningHorizon: pr.FirstContentPlanningHorizon},
		forecastQuote(quote), forecast.QuoteContext{CapacitySeq: c.snapshot.capacitySeq, NewestReservationAt: c.snapshot.newestReservationAt}, now)
}

func forecastQuote(quote PlanEntry) forecast.Quote {
	return forecast.Quote{Confirmed: quote.Confirmed, Demoted: quote.Demoted, Confidence: quote.QuoteConfidence,
		ObservedAt: quote.QuoteObservedAt, CapacitySeq: quote.QuoteCapacitySeq, TTFTP50: quote.QuoteTTFTP50, TTFTP90: quote.QuoteTTFTP90}
}
