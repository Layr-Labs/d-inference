package registry_test

import (
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The reference keeps the former provider-by-boundary epoch-key lookup in this
// benchmark only. Both arms use the same live providers, exact plan, four warm
// machines and result checks in one process; neither runs GPU/model work.
func legacyEpochHolderHints(providers []*production.Provider, holders map[string]indexKernelHolder,
	revisions map[string]*cachepeer.Revision, plan production.CachePlan, routeKey []byte, now time.Time) map[string]production.CacheRoutingHint {
	out := make(map[string]production.CacheRoutingHint)
	for _, p := range providers {
		p.Mu().Lock()
		capability := p.PrefixCacheV2Models["model"]
		revision := revisions[p.ID].Capture()
		p.Mu().Unlock()
		if !production.CapabilityMatchesPlan(capability, plan) {
			continue
		}
		for i := len(plan.Boundaries) - 1; i >= 0; i-- {
			anchor := plan.Boundaries[i]
			key := legacyEpochKey(routeKey, plan, capability.CacheEpoch, anchor)
			holder, ok := holders[key]
			if !ok || holder.Provider != p || !now.Before(holder.ExpiresAt) || holder.StageMs <= 0 {
				continue
			}
			out[p.ID] = production.CacheRoutingHint{Provider: p, Capability: capability, CapabilityRevision: revision,
				PrefillTokensSaved: anchor.TokenCount - holder.RequiredRecomputeTokens,
				CachedTokens:       anchor.TokenCount, StageMs: holder.StageMs, Tier: "ssd"}
			break
		}
	}
	return out
}

func legacyEpochKey(key []byte, plan production.CachePlan, epoch string, anchor protocol.PrefixCacheAnchor) string {
	return cacheactivation.OpaqueHMAC(key, "prefix-v3", plan.CacheScope, plan.ModelAggregateHash,
		plan.PromptContractID, epoch, strconv.Itoa(anchor.TokenCount), anchor.ChainHash)
}

func BenchmarkCacheHolderIndex(b *testing.B) {
	for _, fleetSize := range []int{16, 128, 512} {
		b.Run(fmt.Sprintf("providers=%d/boundaries=64/holders=4", fleetSize), func(b *testing.B) {
			var tracker *cacheIndexKernelFixture
			var query production.CacheHintQuerier
			revisions := make(map[string]*cachepeer.Revision)
			r := production.NewWithDependencies(testLogger(), production.Dependencies{Cache: production.CacheDependencies{
				Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
					tracker = &cacheIndexKernelFixture{Tracker: cachetracker.New(config), config: config}
					return tracker.Tracker
				},
				HintQueries: func(owner production.CacheHintQuery) production.CacheHintQuerier {
					query = owner
					return owner
				},
				Revisions: func(id string) *cachepeer.Revision {
					revisions[id] = cachepeer.NewRevision()
					return revisions[id]
				},
			}})
			config := generationTestConfig(production.CacheRoutingOn)
			config.TTL, config.MaxHolders = time.Minute, 4
			if err := r.ConfigureCacheRouting(config); err != nil {
				b.Fatal(err)
			}
			key := []byte("same-route-key-for-both-arms")
			anchors := make([]protocol.PrefixCacheAnchor, 64)
			for i := range anchors {
				anchors[i] = protocol.PrefixCacheAnchor{TokenCount: (i + 1) * 256, ChainHash: fmt.Sprintf("%064x", i+1)}
			}
			plan := exactTestPlan(anchors...)
			plan = bindDemandPlan(tracker.config.Generation, plan)
			warmAnchor := anchors[31]
			now := time.Now()
			providers := make([]*production.Provider, fleetSize)
			legacy := make(map[string]indexKernelHolder)
			for i := range providers {
				capability := indexTestCapability(i)
				p := r.Register(fmt.Sprintf("provider-%d", i), nil, &protocol.RegisterMessage{PrefixCacheProtocol: 2,
					PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability}})
				providers[i] = p
				if i < 4 {
					holder := indexKernelHolder{ProviderID: p.ID, Provider: p, ModelID: "model",
						ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
						CacheEpoch: capability.CacheEpoch, Anchor: warmAnchor, StageMs: 120,
						UpdatedAt: now, ExpiresAt: now.Add(time.Minute)}
					tracker.UpsertHolderLocked(plan.BoundaryKey(key, warmAnchor), holder)
					legacy[legacyEpochKey(key, plan, capability.CacheEpoch, warmAnchor)] = holder
				}
			}
			for _, arm := range []string{"legacy_epoch_walk", "content_index"} {
				b.Run(arm, func(b *testing.B) {
					b.ReportAllocs()
					for i := 0; i < b.N; i++ {
						var hints map[string]production.CacheRoutingHint
						if arm == "legacy_epoch_walk" {
							hints = legacyEpochHolderHints(providers, legacy, revisions, plan, key, now)
						} else {
							hints, _ = query.Query("model", plan, key, production.CacheRoutingOn, now)
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
