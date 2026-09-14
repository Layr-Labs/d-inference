package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// cacheRoutingHints queries content first, then validates only its possible
// holders. Cold fleet members never incur a second capability/lock walk.
// Holder lookup releases the directory lock before validating providers.
// Quarantine and capability publication use registry -> provider -> directory.
func (r *Registry) cacheRoutingHints(
	model string, plan CachePlan, tracker *cacheRoutingTracker,
	routeKey []byte, mode string, now time.Time,
) map[string]cacheRoutingHint {
	hints, _ := r.cacheRoutingHintsWithObservation(model, plan, tracker, routeKey, mode, now)
	return hints
}

func (r *Registry) cacheRoutingHintsWithObservation(
	model string, plan CachePlan, tracker *cacheRoutingTracker,
	routeKey []byte, mode string, now time.Time,
) (map[string]cacheRoutingHint, CacheOpportunity) {
	observation := CacheOpportunity{}
	if tracker == nil || plan.generation != tracker.generation || tracker.generation.Revoked() || mode != CacheRoutingOn || !plan.present() {
		return nil, observation
	}
	observation.Evaluated = true
	observation.RepeatedPrefixTokens = plan.RepeatedPrefixTokens
	matches := tracker.matchingHolders(plan, routeKey, mode, now)
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
		if tracker.directory.CapabilityRejected(providerID, model, "ssd", candidate.Capability) {
			candidate.Capability.Enabled = false
		}
		if tracker.directory.CapabilityRejected(providerID, model, "memory", candidate.MemoryCapability) {
			candidate.MemoryCapability.Enabled = false
		}
		capabilities[providerID] = candidate
	}
	hints := cacheHintsForMatches(plan, matches, capabilities)
	observation.ValidHolders = len(hints)
	return hints, observation
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
		if !holder.MatchesMeasuredCapability(capability) {
			continue
		}
		stageMs := holder.StageCostAt(match.QueryTime)
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
		hint.generation == nil || hint.generation.Revoked() {
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
