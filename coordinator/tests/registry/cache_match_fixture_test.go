package registry_test

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type cacheHolder = cachetracker.Holder[*production.Provider]
type cacheRoutingMatch = cachetracker.Match[*production.Provider]

type cacheMatchFixture struct {
	config    cachetracker.Config[*production.Provider]
	query     production.CacheHintQuery
	revisions map[string]*cachepeer.Revision

	r            *production.Registry
	tracker      *cachetracker.Tracker[*production.Provider]
	plan         production.CachePlan
	key          []byte
	now          time.Time
	providers    []*production.Provider
	capabilities []protocol.PrefixCacheV2Capability
}

type cacheMatchMutation func(*cacheMatchFixture, cacheHolder, int, int, string) cacheHolder

func newCacheMatchFixture(boundaries, providers, holderMachines, tiers int, dense bool, mutate cacheMatchMutation) *cacheMatchFixture {
	f := &cacheMatchFixture{key: []byte("synthetic-dense-key"), now: time.Now(), revisions: make(map[string]*cachepeer.Revision)}
	f.r = production.NewWithDependencies(testLogger(), production.Dependencies{Cache: production.CacheDependencies{
		Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
			f.config = config
			f.tracker = cachetracker.New(config)
			return f.tracker
		},
		HintQueries: func(query production.CacheHintQuery) production.CacheHintQuerier { f.query = query; return query },
		Revisions: func(id string) *cachepeer.Revision {
			revision := cachepeer.NewRevision()
			f.revisions[id] = revision
			return revision
		},
	}})
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders = time.Hour, 16
	if err := f.r.ConfigureCacheRouting(config); err != nil {
		panic(err)
	}
	anchors := make([]protocol.PrefixCacheAnchor, boundaries)
	for i := range anchors {
		anchors[i] = protocol.PrefixCacheAnchor{TokenCount: (i + 1) * 256, ChainHash: fmt.Sprintf("%064x", i+1)}
	}
	f.plan = exactTestPlan(anchors...)
	f.plan = (&preparationFixture{generation: f.config.Generation}).bind(f.plan)
	for i := 0; i < providers; i++ {
		capability := indexTestCapability(i)
		p := f.r.Register(fmt.Sprintf("synthetic-machine-%d", i), nil, &protocol.RegisterMessage{})
		p.PrefixCacheProtocol, p.PrefixCacheV2Models = 2, map[string]protocol.PrefixCacheV2Capability{"model": capability}
		if tiers == 2 {
			p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
		}
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
				f.tracker.UpsertHolderLocked(cachetracker.CacheTierBoundaryKey(f.key, f.plan, anchor, tier), holder)
			}
		}
	}
	return f
}

func (f *cacheMatchFixture) hints() (map[string]production.CacheRoutingHint, production.CacheOpportunity) {
	return f.query.Query("model", f.plan, f.key, production.CacheRoutingOn, f.now)
}
func (f *cacheMatchFixture) matches() []cacheRoutingMatch {
	return f.query.MatchBoundaries(f.plan, f.key, production.CacheRoutingOn, f.now)
}
