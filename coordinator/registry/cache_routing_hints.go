package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type cacheRoutingMatch struct {
	Holder         cacheHolder
	Tier           string
	EvidenceWeight float64
	queriedAt      time.Time
}

// cacheRoutingHints queries content first, then validates only its possible
// holders. Cold fleet members never incur a second capability/lock walk.
// Tracker and provider locks are never nested: receipts take provider locks
// before the tracker, while the scheduler takes the registry lock before them.
func (r *Registry) cacheRoutingHints(
	model string, plan CachePlan, tracker *cacheRoutingTracker,
	routeKey []byte, mode string, now time.Time,
) map[string]cacheRoutingHint {
	matches := tracker.matchingHolders(plan, routeKey, mode, now)
	if len(matches) == 0 {
		return nil
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
	// A proof quarantine retains the advertised capability but rejects it for
	// routing. Later changes are fenced again by the revision at selection and
	// reservation; the rejected-capability check must not be skipped here.
	for providerID, candidate := range capabilities {
		if tracker.capabilityRejected(providerID, model, "ssd", candidate.Capability) {
			candidate.Capability.Enabled = false
		}
		if tracker.capabilityRejected(providerID, model, "memory", candidate.MemoryCapability) {
			candidate.MemoryCapability.Enabled = false
		}
		capabilities[providerID] = candidate
	}
	return cacheHintsForMatches(plan, matches, capabilities)
}

// matchingHolders computes one keyed digest per request boundary, regardless
// of fleet size. Each tier bucket contains at most maxHolders machines, even
// when every machine has a different epoch. No provider lock or eligibility
// check runs while holding the tracker lock.
func (t *cacheRoutingTracker) matchingHolders(
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
					holder.PromptContractID != plan.PromptContractID || holder.Anchor != anchor ||
					anchor.TokenCount <= holder.RequiredRecomputeTokens {
					continue
				}
				out = append(out, cacheRoutingMatch{Holder: holder, Tier: tier, EvidenceWeight: cacheEvidenceWeight(holder, now), queriedAt: now})
			}
		}
	}
	return out
}

// cacheHintsForMatches retains the longest verified endpoint the provider's
// current selector can execute. Complete checkpoints take priority over the
// resident bank; other dual-tier advertisements have no negotiated selector and
// receive no credit. There is no wire control for choosing a shorter endpoint.
func cacheHintsForMatches(plan CachePlan, matches []cacheRoutingMatch,
	capabilities map[string]cacheRoutingCapability,
) map[string]cacheRoutingHint {
	out := make(map[string]cacheRoutingHint)
	for _, match := range matches {
		holder := match.Holder
		if _, present := out[holder.ProviderID]; present {
			continue
		}
		candidate := capabilities[holder.ProviderID]
		capability := candidate.Capability
		hasSSD := capability.ModelID != ""
		hasMemory := candidate.MemoryCapability.ModelID != ""
		if hasSSD && hasMemory && capability.ReadyBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
			continue
		}
		if match.Tier == "memory" {
			// Complete-checkpoint engines always attempt SSD first, including when
			// there is no SSD holder proof for this request. Do not invent a fallback.
			if hasSSD {
				continue
			}
			capability = candidate.MemoryCapability
		}
		if !capabilityMatchesPlan(capability, plan) ||
			holder.ModelID != capability.ModelID || holder.CacheEpoch != capability.CacheEpoch ||
			holder.Provider != candidate.Provider {
			continue
		}
		// Capability publication can precede tracker cleanup. Even an expired
		// sample binds its holder's fallback to the old contract until a new
		// validated Ready or lookup establishes current evidence.
		if measured := holder.stageMeasurement; measured != nil && measured.capability != capability {
			continue
		}
		stageMs := holder.stageCostAt(match.queriedAt)
		if stageMs <= 0 && match.Tier != "memory" {
			continue
		}
		// Matches arrive deepest first. Do not substitute a cheaper short record:
		// the provider does not accept a coordinator-selected endpoint today.
		out[holder.ProviderID] = cacheRoutingHint{
			generation:         plan.generation,
			PrefillTokensSaved: holder.Anchor.TokenCount - holder.RequiredRecomputeTokens,
			CachedTokens:       holder.Anchor.TokenCount,
			StageMs:            stageMs,
			Provider:           candidate.Provider,
			Capability:         capability,
			CapabilityRevision: candidate.CapabilityRevision,
			Tier:               match.Tier,
			EvidenceWeight:     match.EvidenceWeight,
		}
	}
	return out
}

// currentForProviderLocked fences configuration, capability changes and quarantine after the
// unlocked holder query. Both scan and reservation hold provider.mu here.
func (hint cacheRoutingHint) currentForProviderLocked(provider *Provider, model string) bool {
	if provider == nil || hint.Provider != provider ||
		hint.generation == nil || hint.generation.revoked.Load() {
		return false
	}
	capability, ok := provider.prefixCacheCapabilityLocked(model, hint.Tier)
	return ok &&
		provider.PrefixCacheProtocol >= 2 &&
		provider.prefixCacheRevision == hint.CapabilityRevision &&
		capability == hint.Capability &&
		capability.Enabled &&
		capability.Ready
}
