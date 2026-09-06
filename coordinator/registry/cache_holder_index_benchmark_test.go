package registry

import (
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The reference keeps the former provider-by-boundary epoch-key lookup in this
// benchmark only. Both arms use the same live providers, exact plan, four warm
// machines and result checks in one process; neither runs GPU/model work.
func legacyEpochHolderHints(providers []*Provider, holders map[string]cacheHolder,
	plan CachePlan, routeKey []byte, now time.Time) map[string]cacheRoutingHint {
	out := make(map[string]cacheRoutingHint)
	for _, p := range providers {
		p.mu.Lock()
		capability := p.PrefixCacheV2Models["model"]
		revision := p.prefixCacheRevision
		p.mu.Unlock()
		if !capabilityMatchesPlan(capability, plan) {
			continue
		}
		for i := len(plan.Boundaries) - 1; i >= 0; i-- {
			anchor := plan.Boundaries[i]
			key := legacyEpochKey(routeKey, plan, capability.CacheEpoch, anchor)
			holder, ok := holders[key]
			if !ok || holder.Provider != p || !now.Before(holder.ExpiresAt) || holder.StageMs <= 0 {
				continue
			}
			out[p.ID] = cacheRoutingHint{Provider: p, Capability: capability, CapabilityRevision: revision,
				PrefillTokensSaved: anchor.TokenCount - holder.RequiredRecomputeTokens,
				CachedTokens:       anchor.TokenCount, StageMs: holder.StageMs, Tier: "ssd"}
			break
		}
	}
	return out
}

func legacyEpochKey(key []byte, plan CachePlan, epoch string, anchor protocol.PrefixCacheAnchor) string {
	return opaqueHMAC(key, "prefix-v3", plan.CacheScope, plan.ModelAggregateHash,
		plan.PromptContractID, epoch, strconv.Itoa(anchor.TokenCount), anchor.ChainHash)
}

func BenchmarkCacheHolderIndex(b *testing.B) {
	for _, fleetSize := range []int{16, 128, 512} {
		b.Run(fmt.Sprintf("providers=%d/boundaries=64/holders=4", fleetSize), func(b *testing.B) {
			r := New(testLogger())
			tracker := newCacheRoutingTracker(time.Minute, 4)
			key := []byte("same-route-key-for-both-arms")
			anchors := make([]protocol.PrefixCacheAnchor, 64)
			for i := range anchors {
				anchors[i] = protocol.PrefixCacheAnchor{TokenCount: (i + 1) * 256, ChainHash: fmt.Sprintf("%064x", i+1)}
			}
			plan := exactTestPlan(anchors...)
			plan.generation = tracker.generation
			warmAnchor := anchors[31]
			now := time.Now()
			providers := make([]*Provider, fleetSize)
			legacy := make(map[string]cacheHolder)
			for i := range providers {
				capability := indexTestCapability(i)
				p := &Provider{ID: fmt.Sprintf("provider-%d", i), PrefixCacheProtocol: 2,
					PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{"model": capability}}
				providers[i] = p
				insertTestProvider(r, p)
				if i < 4 {
					holder := cacheHolder{ProviderID: p.ID, Provider: p, ModelID: "model",
						ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
						CacheEpoch: capability.CacheEpoch, Anchor: warmAnchor, StageMs: 120,
						UpdatedAt: now, ExpiresAt: now.Add(time.Minute)}
					tracker.upsertHolderLocked(cacheBoundaryKey(key, plan, warmAnchor), holder)
					legacy[legacyEpochKey(key, plan, capability.CacheEpoch, warmAnchor)] = holder
				}
			}
			for _, arm := range []string{"legacy_epoch_walk", "content_index"} {
				b.Run(arm, func(b *testing.B) {
					b.ReportAllocs()
					for i := 0; i < b.N; i++ {
						var hints map[string]cacheRoutingHint
						if arm == "legacy_epoch_walk" {
							hints = legacyEpochHolderHints(providers, legacy, plan, key, now)
						} else {
							hints = r.cacheRoutingHints("model", plan, tracker, key, CacheRoutingOn, now)
						}
						if len(hints) != 4 || hints[providers[0].ID].CachedTokens != warmAnchor.TokenCount {
							b.Fatalf("wrong holder result: %+v", hints)
						}
					}
				})
			}
		})
	}
}
