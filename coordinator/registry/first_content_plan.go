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

func firstContentPlanRetentionLess(candidate *routingCandidate, entry planEntry, prefer bool) bool {
	feasible := candidate.firstContent.Status == "feasible"
	if prefer && feasible != entry.firstContentFeasible {
		return feasible
	}
	return candidate.costMs < entry.view.CostMs
}

// remainingEntries takes a bounded value snapshot in current quote order.
// The provider state is read only after releasing the leaf plan lock.
func (dp *DispatchPlan) remainingEntries() []planEntry {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return append([]planEntry(nil), dp.entries[dp.cursor:]...)
}

func (dp *DispatchPlan) restoreOrdinaryOrder() {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.firstContentPreferred {
		dp.resortTailLocked()
		dp.firstContentPreferred = false
	}
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
