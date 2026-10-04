package registry

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type cacheMatchFixture struct {
	r            *Registry
	tracker      *cacheRoutingTracker
	plan         CachePlan
	key          []byte
	now          time.Time
	providers    []*Provider
	capabilities []protocol.PrefixCacheV2Capability
}

type cacheMatchMutation func(*cacheMatchFixture, cacheHolder, int, int, string) cacheHolder

func newCacheMatchFixture(boundaries, providers, holderMachines, tiers int, dense bool, mutate cacheMatchMutation) *cacheMatchFixture {
	f := &cacheMatchFixture{r: New(testLogger()), tracker: newCacheRoutingTracker(time.Hour, 16), key: []byte("synthetic-dense-key"), now: time.Now()}
	anchors := make([]protocol.PrefixCacheAnchor, boundaries)
	for i := range anchors {
		anchors[i] = protocol.PrefixCacheAnchor{TokenCount: (i + 1) * 256, ChainHash: fmt.Sprintf("%064x", i+1)}
	}
	f.plan = exactTestPlan(anchors...)
	f.plan.generation = f.tracker.generation
	for i := 0; i < providers; i++ {
		capability := indexTestCapability(i)
		p := &Provider{ID: fmt.Sprintf("synthetic-machine-%d", i), PrefixCacheProtocol: 2, PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{"model": capability}}
		if tiers == 2 {
			p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
		}
		insertTestProvider(f.r, p)
		f.providers = append(f.providers, p)
		f.capabilities = append(f.capabilities, capability)
	}
	for i := 0; i < holderMachines; i++ {
		for j, anchor := range anchors {
			if holderMachines > 16 && i/16 != j%((holderMachines+15)/16) {
				continue
			}
			if !dense && j != boundaries/2 {
				continue
			}
			for ti := 0; ti < tiers; ti++ {
				tier := "ssd"
				stage := 120.0
				if ti == 1 {
					tier = "memory"
					stage = 0
				}
				capability := f.capabilities[i]
				holder := cacheHolder{ProviderID: f.providers[i].ID, Provider: f.providers[i], ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch, BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode, Tier: tier, Anchor: anchor, StageMs: stage, UpdatedAt: f.now, ExpiresAt: f.now.Add(time.Hour)}
				if mutate != nil {
					holder = mutate(f, holder, j, i, tier)
				}
				f.tracker.upsertHolderLocked(cacheTierKey(cacheBoundaryKey(f.key, f.plan, anchor), tier), holder)
			}
		}
	}
	return f
}
