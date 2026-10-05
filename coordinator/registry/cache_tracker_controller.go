package registry

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
)

type cacheRoutingTracker struct {
	demand      *cacheDemandTracker
	generation  *cacheRoutingGeneration
	mu          sync.Mutex
	settings    cachetracker.Settings
	core        *cachetracker.Tracker[*Provider]
	hintQuery   CacheHintQuerier
	maintenance CacheMaintainer
	affinity    CacheAffinityEvaluator
	// persister keeps the durable copy (cache_persistence.go); nil when the
	// store cannot persist or persistence is off. restoring is set while
	// bound rows re-enter through upsertHolderLocked so they are not re-marked.
	persister    *cachepersist.Persister
	holders      *cacheindex.Holders[cacheHolder]
	attempts     *cacheindex.Records[string, cacheAttempt]
	holderOrder  *cacheindex.Order[cacheindex.HolderRef, cacheindex.HolderRef]
	attemptOrder *cacheindex.Order[cacheindex.AttemptRef, string]
	// The per-provider indexes hold the same order entries as the heaps and
	// change only where the heaps change, so a disconnect or a capability
	// change visits that provider's entries instead of every bucket and
	// attempt (cache_provider_index.go).
	holdersByProvider  *cacheindex.ProviderIndex[*cacheHolderOrderEntry]
	attemptsByProvider *cacheindex.ProviderIndex[*cacheAttemptOrderEntry]
	v2Sequences        *cacheindex.Records[cacheV2SequenceKey, uint64]
	rejectedV2         *cacheindex.Records[cacheV2ProviderModelKey, cacheV2Fence]
	proofs             *cachetracker.Proofs
	// The receipt/evidence clock is immutable after construction. Nil uses
	// time.Now; separate demand/activation/TTFT clocks remain unchanged.
	clock func() time.Time
}

func (t *cacheRoutingTracker) now() time.Time {
	if t.clock != nil {
		return t.clock()
	}
	return time.Now()
}

func newCacheRoutingTracker(ttl time.Duration, maxHolders int) *cacheRoutingTracker {
	return newCacheRoutingTrackerWithClock(ttl, maxHolders, nil)
}

func newCacheRoutingTrackerWithClock(ttl time.Duration, maxHolders int, now func() time.Time) *cacheRoutingTracker {
	return newCacheRoutingTrackerWithDependencies(ttl, maxHolders, CacheDependencies{Now: now})
}

func newCacheRoutingTrackerWithDependencies(ttl time.Duration, maxHolders int, deps CacheDependencies) *cacheRoutingTracker {
	if ttl <= 0 {
		ttl = defaultCacheRoutingTTL
	}
	if maxHolders <= 0 {
		maxHolders = defaultCacheRoutingMaxHolders
	}
	settings := cachetracker.Settings{
		TTL: ttl, MaxHolders: maxHolders, MaxEntries: cacheRoutingMaxEntries, MaxAttempts: cacheRoutingMaxAttempts,
	}
	if deps.MaxEntries > 0 {
		settings.MaxEntries = deps.MaxEntries
	}
	if deps.MaxAttempts > 0 {
		settings.MaxAttempts = deps.MaxAttempts
	}
	return newCacheRoutingTrackerWithSettings(settings, deps)
}

func newCacheRoutingTrackerWithSettings(settings cachetracker.Settings, deps CacheDependencies) *cacheRoutingTracker {
	generation := &cacheRoutingGeneration{}
	if deps.Generations != nil {
		generation = deps.Generations()
	}
	var attempts *cacheindex.Records[string, cacheAttempt]
	if deps.Attempts != nil {
		attempts = deps.Attempts()
	}
	if attempts == nil {
		attempts = cacheindex.NewRecords[string, cacheAttempt]()
	}
	var attemptBudget *cachetracker.AttemptBudget
	if deps.AttemptBudgets != nil {
		attemptBudget = deps.AttemptBudgets()
	}
	if attemptBudget == nil {
		attemptBudget = cachetracker.NewAttemptBudget(cacheRoutingMaxAttemptBytes)
	}
	var fences *cacheindex.Records[cacheV2ProviderModelKey, cacheV2Fence]
	if deps.Fences != nil {
		fences = deps.Fences()
	}
	if fences == nil {
		fences = cacheindex.NewRecords[cacheV2ProviderModelKey, cacheV2Fence]()
	}
	var proofs *cachetracker.Proofs
	if deps.Proofs != nil {
		proofs = deps.Proofs(generation, fences)
	}
	if proofs == nil {
		proofs = cachetracker.NewProofs(generation, fences)
	}
	var holders *cacheindex.Holders[cacheHolder]
	if deps.Holders != nil {
		holders = deps.Holders()
	}
	if holders == nil {
		holders = cacheindex.NewHolders[cacheHolder]()
	}
	tracker := &cacheRoutingTracker{
		clock:      deps.Now,
		generation: generation,
		demand:     newCacheDemandTrackerWithDependencies(cacheDemandMaxEntries, settings.TTL, deps),
		settings:   settings,
		holders:    holders, attempts: attempts,
		holderOrder: cacheindex.NewHolderOrder(), attemptOrder: cacheindex.NewAttemptOrder(),
		holdersByProvider:  cacheindex.NewProviderIndex[*cacheHolderOrderEntry](),
		attemptsByProvider: cacheindex.NewProviderIndex[*cacheAttemptOrderEntry](),
		v2Sequences:        cacheindex.NewRecords[cacheV2SequenceKey, uint64](),
		rejectedV2:         fences,
		proofs:             proofs,
	}
	config := cachetracker.Config[*Provider]{
		Settings: settings, Now: deps.Now, Generation: generation,
		Holders: tracker.holders, Attempts: tracker.attempts,
		HolderOrder: tracker.holderOrder, AttemptOrder: tracker.attemptOrder,
		HolderProviders: tracker.holdersByProvider, AttemptProviders: tracker.attemptsByProvider,
		Sequences: tracker.v2Sequences, Proofs: proofs, AttemptBudget: attemptBudget,
	}
	if deps.Trackers != nil {
		tracker.core = deps.Trackers(config)
	}
	if tracker.core == nil {
		tracker.core = cachetracker.New(config)
	}
	tracker.maintenance = CacheMaintenance{tracker: tracker}
	if deps.Maintenance != nil {
		tracker.maintenance = deps.Maintenance(CacheMaintenance{tracker: tracker})
	}
	tracker.affinity = CacheAffinityEvaluation{tracker: tracker}
	if deps.Affinities != nil {
		tracker.affinity = deps.Affinities(CacheAffinityEvaluation{tracker: tracker})
	}
	return tracker
}
