package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Full materialization from the pre-grouping implementation is an independent
// output oracle. Production queries must use the tracker compatibility groups.
func (f *cacheMatchFixture) referenceHints() (map[string]production.CacheRoutingHint, production.CacheOpportunity) {
	observation := production.CacheOpportunity{}
	if !f.plan.Authenticates(f.config.Generation) || !f.config.Generation.Active() || !f.plan.Present() {
		return nil, observation
	}
	observation.Evaluated, observation.RepeatedPrefixTokens = true, f.plan.RepeatedPrefixTokens
	matches := f.referenceMatches()
	if len(matches) == 0 {
		return nil, observation
	}
	capabilities := make(map[string]production.CacheRoutingCapability)
	for _, match := range matches {
		id := match.Holder.ProviderID
		if _, seen := capabilities[id]; seen {
			continue
		}
		provider := f.r.GetProvider(id)
		candidate := production.CacheRoutingCapability{Provider: provider}
		if provider != nil {
			provider.Mu().Lock()
			if provider.PrefixCacheProtocol >= 2 {
				candidate.Capability, candidate.MemoryCapability = provider.PrefixCacheV2Models["model"], provider.PrefixCacheMemoryModels["model"]
				candidate.CapabilityRevision = f.revisions[id].Capture()
			}
			provider.Mu().Unlock()
		}
		capabilities[id] = candidate
	}
	observation.MatchingHolders = len(capabilities)
	for id, candidate := range capabilities {
		if f.config.Proofs.Rejected(cachetracker.FenceKey{ProviderID: id, ModelID: "model", Tier: "ssd"}, candidate.Capability, f.now) {
			candidate.Capability.Enabled = false
		}
		if f.config.Proofs.Rejected(cachetracker.FenceKey{ProviderID: id, ModelID: "model", Tier: "memory"}, candidate.MemoryCapability, f.now) {
			candidate.MemoryCapability.Enabled = false
		}
		capabilities[id] = candidate
	}
	hints := production.CacheHintsForMatches(f.plan, matches, capabilities)
	observation.ValidHolders = len(hints)
	return hints, observation
}

func (f *cacheMatchFixture) referenceMatches() []cacheRoutingMatch {
	if !f.plan.Authenticates(f.config.Generation) || !f.config.Generation.Active() || !f.plan.Present() || len(f.key) == 0 {
		return nil
	}
	keys := make([]string, len(f.plan.Boundaries))
	for i, anchor := range f.plan.Boundaries {
		keys[i] = f.plan.BoundaryKey(f.key, anchor)
	}
	f.tracker.SweepIfDueLocked(f.now)
	out := make([]cacheRoutingMatch, 0)
	for i := len(f.plan.Boundaries) - 1; i >= 0; i-- {
		anchor := f.plan.Boundaries[i]
		for _, tier := range [...]string{"ssd", "memory"} {
			key := cachetracker.CacheTierKey(keys[i], tier)
			for id := range f.config.Holders.Entries(key) {
				holder, live := f.tracker.ActiveHolderLocked(key, id, f.now)
				if !live || holder.ModelAggregateHash != f.plan.ModelAggregateHash || holder.PromptContractID != f.plan.PromptContractID || !cachetracker.AnchorMatches(holder.Anchor, anchor) || anchor.TokenCount <= holder.RequiredRecomputeTokens {
					continue
				}
				out = append(out, holder.MatchAt(tier, f.now))
			}
		}
	}
	return out
}
