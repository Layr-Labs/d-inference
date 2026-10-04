package registry

import "time"

// Full materialization from e8ca1dcf is an independent output oracle and
// benchmark baseline; production queries must use matchingHolders.
func (r *Registry) cacheRoutingHintsMaterializationReference(
	model string, plan CachePlan, tracker *cacheRoutingTracker,
	routeKey []byte, mode string, now time.Time,
) (map[string]cacheRoutingHint, CacheOpportunity) {
	observation := CacheOpportunity{}
	if tracker == nil || plan.generation != tracker.generation || tracker.generation.revoked.Load() || mode != CacheRoutingOn || !plan.present() {
		return nil, observation
	}
	observation.Evaluated = true
	observation.RepeatedPrefixTokens = plan.RepeatedPrefixTokens
	matches := tracker.matchingHoldersMaterializationReference(plan, routeKey, mode, now)
	if len(matches) == 0 {
		return nil, observation
	}
	capabilities := make(map[string]cacheRoutingCapability)
	r.mu.RLock()
	for _, match := range matches {
		holder := match.Holder
		if _, seen := capabilities[holder.ProviderID]; seen {
			continue
		}
		capabilities[holder.ProviderID] = cacheRoutingCapability{Provider: r.providers[holder.ProviderID]}
	}
	r.mu.RUnlock()
	for providerID, candidate := range capabilities {
		provider := candidate.Provider
		if provider != nil {
			provider.mu.Lock()
			if provider.PrefixCacheProtocol >= 2 {
				candidate.Capability = provider.PrefixCacheV2Models[model]
				candidate.MemoryCapability = provider.PrefixCacheMemoryModels[model]
				candidate.CapabilityRevision = provider.prefixCacheRevision
			}
			provider.mu.Unlock()
		}
		capabilities[providerID] = candidate
	}
	observation.MatchingHolders = len(capabilities)
	// A proof quarantine retains the advertised capability but rejects it for
	// routing. Later changes are fenced again by the revision at selection and
	// reservation; the rejected-capability check must not be skipped here.
	for providerID, candidate := range capabilities {
		if tracker.capabilityRejected(providerID, model, "ssd", candidate.Capability, now) {
			candidate.Capability.Enabled = false
		}
		if tracker.capabilityRejected(providerID, model, "memory", candidate.MemoryCapability, now) {
			candidate.MemoryCapability.Enabled = false
		}
		capabilities[providerID] = candidate
	}
	hints := cacheHintsForMatches(plan, matches, capabilities)
	observation.ValidHolders = len(hints)
	return hints, observation
}

// matchingHoldersMaterializationReference computes one keyed digest per request boundary, regardless
// of fleet size. Each tier bucket contains at most maxHolders machines, even
// when every machine has a different epoch. No provider lock or eligibility
// check runs while holding the tracker lock.
func (t *cacheRoutingTracker) matchingHoldersMaterializationReference(
	plan CachePlan, routeKey []byte, mode string, now time.Time,
) []cacheRoutingMatch {
	if t == nil || mode != CacheRoutingOn || !plan.present() || len(routeKey) == 0 ||
		plan.generation != t.generation || t.generation.revoked.Load() {
		return nil
	}
	keys := make([]string, len(plan.Boundaries))
	for i, anchor := range plan.Boundaries {
		keys[i] = cacheBoundaryKey(routeKey, plan, anchor)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.generation.revoked.Load() {
		return nil
	}
	t.sweepIfDueLocked(now)
	out := make([]cacheRoutingMatch, 0)
	for i := len(plan.Boundaries) - 1; i >= 0; i-- {
		anchor := plan.Boundaries[i]
		for _, tier := range [...]string{"ssd", "memory"} {
			key := cacheTierKey(keys[i], tier)
			for providerID := range t.holders[key] {
				holder, live := t.activeHolderLocked(key, providerID, now)
				if !live || holder.ModelAggregateHash != plan.ModelAggregateHash ||
					holder.PromptContractID != plan.PromptContractID || !anchorMatches(holder.Anchor, anchor) ||
					anchor.TokenCount <= holder.RequiredRecomputeTokens {
					continue
				}
				out = append(out, cacheRoutingMatch{Holder: holder, Tier: tier, EvidenceWeight: cacheEvidenceWeight(holder, now), queriedAt: now})
			}
		}
	}
	return out
}
