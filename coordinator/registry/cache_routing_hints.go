package registry

import (
	"time"
)

func (r *Registry) prefixCacheV2CapabilitiesForModel(
	model string,
) map[string]cacheRoutingCapability {
	r.mu.RLock()
	providers := make([]*Provider, 0, len(r.providers))
	tracker := r.cacheRouting
	for _, provider := range r.providers {
		providers = append(providers, provider)
	}
	r.mu.RUnlock()
	out := make(map[string]cacheRoutingCapability)
	for _, provider := range providers {
		provider.mu.Lock()
		capability, ok := provider.PrefixCacheV2Models[model]
		providerID := provider.ID
		version := provider.PrefixCacheProtocol
		revision := provider.prefixCacheRevision
		provider.mu.Unlock()
		if ok && version >= 2 &&
			(tracker == nil || !tracker.capabilityRejected(providerID, model, capability)) {
			out[providerID] = cacheRoutingCapability{
				Provider: provider, Capability: capability,
				CapabilityRevision: revision,
			}
		}
	}
	return out
}

// hints returns each provider's longest live exact boundary. Unknown staging
// cost receives no hint, hence no discount.
func (t *cacheRoutingTracker) hints(
	plan CachePlan,
	capabilities map[string]cacheRoutingCapability,
	routeKey []byte,
	mode string,
	now time.Time,
) map[string]cacheRoutingHint {
	if t == nil || mode != CacheRoutingOn || !plan.present() || len(routeKey) == 0 {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	out := make(map[string]cacheRoutingHint)
	for providerID, candidate := range capabilities {
		capability := candidate.Capability
		if capability.ModelAggregateHash != plan.ModelAggregateHash ||
			capability.PromptContractID != plan.PromptContractID ||
			!capability.Enabled || !capability.Ready {
			continue
		}
		for index := len(plan.Boundaries) - 1; index >= 0; index-- {
			anchor := plan.Boundaries[index]
			key := cacheBoundaryKey(routeKey, plan, capability.CacheEpoch, anchor)
			holder, ok := t.activeHolderLocked(key, providerID, now)
			if !ok ||
				holder.ModelID != capability.ModelID ||
				holder.ModelAggregateHash != capability.ModelAggregateHash ||
				holder.PromptContractID != capability.PromptContractID ||
				holder.CacheEpoch != capability.CacheEpoch ||
				holder.Anchor != anchor ||
				holder.Provider != candidate.Provider ||
				holder.StageMs <= 0 {
				continue
			}
			saved := anchor.TokenCount - holder.RequiredRecomputeTokens
			if saved <= 0 {
				continue
			}
			out[providerID] = cacheRoutingHint{
				PrefillTokensSaved: saved,
				CachedTokens:       anchor.TokenCount,
				StageMs:            holder.StageMs,
				Provider:           candidate.Provider,
				Capability:         capability,
				CapabilityRevision: candidate.CapabilityRevision,
			}
			break
		}
	}
	return out
}

// currentForProvider closes the gap between the unlocked tracker snapshot and
// the locked scheduler scan. Capability heartbeats and proof quarantine mutate
// the revision under the same provider lock, so stale hints fail cold before
// they can influence provider selection.
func (hint cacheRoutingHint) currentForProvider(provider *Provider, model string) bool {
	if provider == nil || hint.Provider != provider {
		return false
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	capability, ok := provider.PrefixCacheV2Models[model]
	return ok &&
		provider.PrefixCacheProtocol >= 2 &&
		provider.prefixCacheRevision == hint.CapabilityRevision &&
		capability == hint.Capability &&
		capability.Enabled &&
		capability.Ready
}
