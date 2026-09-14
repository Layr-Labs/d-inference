package registry

// Plan preference only changes which retained identity is tried first. A
// forecast is never a terminal rejection: unknown and predicted-late entries
// remain unconsumed until no preferred entry can reserve.
type firstContentPlanPreference struct {
	claim           bool
	feasibleOnly    bool
	diverseOnly     bool
	decodeFloorOnly bool
}

type firstContentPlanTier struct {
	feasible, diverse, decodeFloor bool
}

func firstContentPlanTierOf(entry planEntry, avoidVersion string, minDecodeTPS float64) firstContentPlanTier {
	return firstContentPlanTier{
		feasible:    entry.firstContentFeasible,
		diverse:     avoidVersion == "" || entry.binaryVersion != avoidVersion,
		decodeFloor: minDecodeTPS <= 0 || entry.projectedDecodeTPS >= minDecodeTPS,
	}
}

func (tier firstContentPlanTier) before(other firstContentPlanTier) bool {
	if tier.feasible != other.feasible {
		return tier.feasible
	}
	if tier.diverse != other.diverse {
		return tier.diverse
	}
	return tier.decodeFloor && !other.decodeFloor
}

func retainFirstContentPlanEntries(pool []*routingCandidate, winner *routingCandidate, prefer bool, avoidVersion string, minDecodeTPS float64) []planEntry {
	entries := make([]planEntry, 0, dispatchPlanMaxAlternates)
	for _, candidate := range pool {
		if candidate == winner {
			continue
		}
		entry := planEntry{
			provider:             candidate.provider,
			firstContentFeasible: candidate.firstContent.Status == "feasible",
			binaryVersion:        candidate.snapshot.binaryVersion,
			projectedDecodeTPS:   projectedPerRequestDecodeTPS(&candidate.snapshot),
			view: PlanEntry{
				ProviderID:  candidate.provider.ID,
				CostMs:      candidate.costMs,
				TTFTMs:      candidate.breakdown.TTFTMs,
				RawTTFTMs:   candidate.breakdown.RawTTFTMs,
				StateMs:     candidate.breakdown.StateMs,
				ModelLoaded: candidate.snapshot.modelLoaded,
				SlotState:   candidate.snapshot.slotState,
				ChipFamily:  candidate.snapshot.chipFamily,
			},
		}
		pos := len(entries)
		tier := firstContentPlanTierOf(entry, avoidVersion, minDecodeTPS)
		for pos > 0 {
			previous := entries[pos-1]
			previousTier := firstContentPlanTierOf(previous, avoidVersion, minDecodeTPS)
			before := entry.view.CostMs < previous.view.CostMs
			if prefer && tier != previousTier {
				before = tier.before(previousTier)
			}
			if !before {
				break
			}
			pos--
		}
		if pos == dispatchPlanMaxAlternates {
			continue
		}
		if len(entries) < dispatchPlanMaxAlternates {
			entries = append(entries, planEntry{})
		}
		copy(entries[pos+1:], entries[pos:])
		entries[pos] = entry
	}
	return entries
}

// Retry policies can change after the primary fails. Re-rank quote evidence
// using the latest request policy while keeping the provider measurements
// explicitly scan-time; reservation still rechecks live versions and rates.
func (dp *DispatchPlan) updateFirstContentRequest(pr *PendingRequest) {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.avoidVersion != pr.Traits.AvoidVersion || dp.minDecodeTPS != pr.MinDecodeTPS {
		dp.avoidVersion, dp.minDecodeTPS = pr.Traits.AvoidVersion, pr.MinDecodeTPS
		dp.resortTailLocked()
	}
}

// remainingEntries takes a bounded value snapshot in current quote order.
// The provider state is read only after releasing the leaf plan lock.
func (dp *DispatchPlan) remainingEntries() []planEntry {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return append([]planEntry(nil), dp.entries[dp.cursor:]...)
}

// View APIs are called without a registry lock. Observe the current mode
// before reading the shortlist, preserving registry→plan lock order. Reserve
// paths already hold r.mu and call useFirstContentMode directly instead.
func (dp *DispatchPlan) syncFirstContentMode() {
	if dp.registry == nil {
		return
	}
	dp.registry.mu.RLock()
	defer dp.registry.mu.RUnlock()
	dp.useFirstContentMode(dp.registry.firstContentRoutingMode == FirstContentRoutingPrefer)
}

// useFirstContentMode swaps bounded shortlists on a mode transition. Sorting
// the preferred list alone cannot recover cheap ordinary candidates it never
// retained. Preserve attempt history and copy fresh quotes across overlapping
// identities, then leave the inactive tail available for a later transition.
func (dp *DispatchPlan) useFirstContentMode(prefer bool) {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	dp.firstContentQuoteUnavailable = prefer && !dp.hasFirstContentPools
	if !dp.hasFirstContentPools || dp.firstContentPreferred == prefer {
		return
	}
	oldTail := append([]planEntry(nil), dp.entries[dp.cursor:]...)
	nextTail := make([]planEntry, 0, len(dp.alternateEntries))
	for _, entry := range dp.alternateEntries {
		if _, attempted := dp.attempted[entry.view.ProviderID]; attempted {
			continue
		}
		for _, current := range oldTail {
			if current.provider == entry.provider && current.view.ProviderID == entry.view.ProviderID {
				copyFirstContentPlanQuote(&entry.view, current.view)
				break
			}
		}
		nextTail = append(nextTail, entry)
	}
	dp.entries = append(dp.entries[:dp.cursor:dp.cursor], nextTail...)
	dp.alternateEntries = oldTail
	dp.firstContentPreferred = prefer
	dp.resortTailLocked()
}

func copyFirstContentPlanQuote(dst *PlanEntry, src PlanEntry) {
	dst.Confirmed, dst.Demoted = src.Confirmed, src.Demoted
	dst.QuoteTTFTP50, dst.QuoteTTFTP90 = src.QuoteTTFTP50, src.QuoteTTFTP90
	dst.QuoteAvailableTokens, dst.QuoteConfidence = src.QuoteAvailableTokens, src.QuoteConfidence
}

// A quote may arrive after its provider's shortlist became inactive. Keep it
// on both retained copies so a later mode switch neither drops the result nor
// resurrects an older confirmation after demotion. Caller holds plan.mu.
func (dp *DispatchPlan) updateFirstContentPlanQuoteLocked(providerID string, update func(*PlanEntry)) {
	for i := dp.cursor; i < len(dp.entries); i++ {
		if dp.entries[i].view.ProviderID == providerID {
			update(&dp.entries[i].view)
		}
	}
	for i := range dp.alternateEntries {
		if dp.alternateEntries[i].view.ProviderID == providerID {
			update(&dp.alternateEntries[i].view)
		}
	}
	dp.resortTailLocked()
}

// consumeEntry atomically claims an arbitrary retained identity while keeping
// the remaining tail in its original order. A competing retry/hedge may have
// consumed it after inspection, in which case it cannot be dispatched twice.
// Caller may hold r.mu and p.mu; plan.mu remains a leaf lock.
func (dp *DispatchPlan) consumeEntry(entry planEntry) bool {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		if dp.entries[i].provider != entry.provider || dp.entries[i].view.ProviderID != entry.view.ProviderID {
			continue
		}
		claimed := dp.entries[i]
		copy(dp.entries[dp.cursor+1:i+1], dp.entries[dp.cursor:i])
		dp.entries[dp.cursor] = claimed
		dp.cursor++
		dp.attempted[entry.view.ProviderID] = struct{}{}
		return true
	}
	return false
}

func (r *Registry) prepareFirstContentPlanHints(model string, pr *PendingRequest) (*cacheRoutingTracker, string) {
	r.mu.RLock()
	mode := r.firstContentRoutingMode
	r.mu.RUnlock()
	if mode == FirstContentRoutingPrefer {
		tracker, cacheMode := r.prepareCacheRoutingHints(model, pr)
		// Holder lookup is not a complete candidate scan. Do not publish zero
		// usable/credited totals as a measured cache-opportunity population.
		pr.CacheOpportunity = CacheOpportunity{}
		return tracker, cacheMode
	}
	if mode == FirstContentRoutingShadow {
		// Shadow uses the holder evidence for its estimate without changing the
		// attempt's existing cache-selection metadata.
		shadow := &PendingRequest{CachePlan: pr.CachePlan}
		tracker, cacheMode := r.prepareCacheRoutingHints(model, shadow)
		pr.cacheRoutingHints = shadow.cacheRoutingHints
		return tracker, cacheMode
	}
	return nil, ""
}

// reserveFirstContentPlan shares the ordinary plan reservation's complete
// gate-and-debit closure. Feasibility comes before the existing soft version
// and decode preferences, then each tier retains current quote/cost order.
// Each pass visits at most eight entries; it never performs a fleet scan.
// Caller holds the registry commit lock, keeping identities and mode stable.
func (r *Registry) reserveFirstContentPlan(
	pr *PendingRequest,
	plan *DispatchPlan,
	exclude map[string]struct{},
	tryReserve func(planEntry, firstContentPlanPreference) (*Provider, RoutingDecision, bool),
	skips *[]PlanSkip,
) (*Provider, RoutingDecision, []PlanSkip) {
	for _, feasibleOnly := range []bool{true, false} {
		versionPasses := []bool{false}
		if pr.Traits.AvoidVersion != "" {
			versionPasses = []bool{true, false}
		}
		for _, diverseOnly := range versionPasses {
			decodePasses := []bool{false}
			if pr.MinDecodeTPS > 0 {
				decodePasses = []bool{true, false}
			}
			for _, decodeFloorOnly := range decodePasses {
				preference := firstContentPlanPreference{
					claim: true, feasibleOnly: feasibleOnly,
					diverseOnly: diverseOnly, decodeFloorOnly: decodeFloorOnly,
				}
				for _, entry := range plan.remainingEntries() {
					id := entry.view.ProviderID
					reason := PlanSkipReason("")
					if _, excluded := exclude[id]; excluded {
						reason = PlanSkipExcluded
					} else if live, ok := r.providers[id]; !ok || live != entry.provider {
						reason = PlanSkipStaleSession
					}
					if reason != "" {
						if plan.consumeEntry(entry) {
							*skips = append(*skips, PlanSkip{ProviderID: id, Reason: reason})
						}
						continue
					}
					if provider, decision, ok := tryReserve(entry, preference); ok {
						return provider, decision, *skips
					}
				}
			}
		}
	}
	*skips = append(*skips, PlanSkip{Reason: PlanSkipExhausted})
	return nil, RoutingDecision{Model: plan.model}, *skips
}
