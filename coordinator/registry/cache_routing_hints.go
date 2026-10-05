package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type cacheRoutingMatch = cachetracker.Match[*Provider]

type CacheHintQuerier interface {
	Query(model string, plan CachePlan, routeKey []byte, mode string, now time.Time) (map[string]CacheRoutingHint, CacheOpportunity)
}

// CacheHintQuery binds one generation's content query to the registry's live
// provider directory. Provider snapshots are still resolved for each query.
type CacheHintQuery struct {
	registry *Registry
	tracker  *cacheRoutingTracker
}

// Query checks content first, then validates only possible holders. Provider
// and tracker locks are never nested; receipts take the provider lock first.
func (query CacheHintQuery) Query(model string, plan CachePlan, routeKey []byte, mode string, now time.Time) (map[string]CacheRoutingHint, CacheOpportunity) {
	r, tracker := query.registry, query.tracker
	observation := CacheOpportunity{}
	if tracker == nil || !plan.Authenticates(tracker.generation) || !tracker.generation.Active() || mode != CacheRoutingOn || !plan.Present() {
		return nil, observation
	}
	observation.Evaluated = true
	observation.RepeatedPrefixTokens = plan.RepeatedPrefixTokens
	matches := query.MatchBoundaries(plan, routeKey, mode, now)
	if len(matches) == 0 {
		return nil, observation
	}
	capabilities := make(map[string]CacheRoutingCapability)
	r.mu.RLock()
	for _, match := range matches {
		holder := match.Holder
		if _, seen := capabilities[holder.ProviderID]; seen {
			continue
		}
		capabilities[holder.ProviderID] = CacheRoutingCapability{Provider: r.providers[holder.ProviderID]}
	}
	r.mu.RUnlock()
	for providerID, candidate := range capabilities {
		provider := candidate.Provider
		if provider != nil {
			provider.mu.Lock()
			if provider.PrefixCacheProtocol >= 2 {
				candidate.Capability = provider.PrefixCacheV2Models[model]
				candidate.MemoryCapability = provider.PrefixCacheMemoryModels[model]
				candidate.CapabilityRevision = provider.prefixCacheRevision.Capture()
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
	hints := CacheHintsForMatches(plan, matches, capabilities)
	observation.ValidHolders = len(hints)
	return hints, observation
}

// MatchBoundaries resolves content evidence before the query inspects provider
// capabilities. Key derivation remains outside the generation's receipt lock.
// Each boundary computes one digest regardless of fleet size; no provider lock
// or eligibility check runs while holding the tracker lock.
func (query CacheHintQuery) MatchBoundaries(plan CachePlan, routeKey []byte, mode string, now time.Time) []cachetracker.Match[*Provider] {
	t := query.tracker
	if t == nil || mode != CacheRoutingOn || !plan.Present() || len(routeKey) == 0 ||
		!plan.Authenticates(t.generation) || !t.generation.Active() {
		return nil
	}
	keys := make([]string, len(plan.Boundaries))
	for i, anchor := range plan.Boundaries {
		keys[i] = cacheBoundaryKey(routeKey, plan, anchor)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.core.MatchBoundaries(plan, keys, now)
}

// CacheHintsForMatches retains the longest verified endpoint the provider's
// current selector can execute. Complete checkpoints take priority over the
// resident bank; other dual-tier advertisements have no negotiated selector and
// receive no credit. There is no wire control for choosing a shorter endpoint.
func CacheHintsForMatches(plan CachePlan, matches []cacheRoutingMatch,
	capabilities map[string]CacheRoutingCapability,
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
		if !CapabilityMatchesPlan(capability, plan) ||
			holder.ModelID != capability.ModelID || holder.CacheEpoch != capability.CacheEpoch ||
			holder.Provider != candidate.Provider {
			continue
		}
		// Capability publication can precede tracker cleanup. Even an expired
		// sample binds its holder's fallback to the old contract until a new
		// validated Ready or lookup establishes current evidence.
		if measured := holder.Measurement; measured != nil && !measured.Matches(capability) {
			continue
		}
		stageMs := match.StageCost()
		if stageMs <= 0 && match.Tier != "memory" {
			continue
		}
		// Matches arrive deepest first. Do not substitute a cheaper short record:
		// the provider does not accept a coordinator-selected endpoint today.
		out[holder.ProviderID] = cacheRoutingHint{
			generation:         plan.Provenance(),
			evidence:           holder.Evidence,
			ExpiresAt:          holder.ExpiresAt,
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

// CurrentForProviderLocked fences holder loss, configuration, capability changes and quarantine after the
// unlocked holder query. Both scan and reservation hold provider.mu here.
func (hint CacheRoutingHint) CurrentForProviderLocked(provider *Provider, model string) bool {
	if provider == nil || hint.Provider != provider ||
		!hint.evidence.Current() ||
		hint.generation == nil || !hint.generation.Active() {
		return false
	}
	capability, ok := provider.prefixCacheCapabilityLocked(model, hint.Tier)
	return ok &&
		provider.PrefixCacheProtocol >= 2 &&
		provider.prefixCacheRevision.Accepts(hint.CapabilityRevision) &&
		capability == hint.Capability &&
		capability.Enabled &&
		capability.Ready
}
