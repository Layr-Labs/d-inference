package registry_test

import (
	"fmt"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	indexKernelMaxHolders         = 4
	indexKernelMaxEntries         = 250_000
	indexKernelMaxAttempts        = 50_000
	indexKernelSweepRemovals      = 1024
	indexKernelAttemptTTL         = 2 * time.Minute
	indexKernelInFlightAttemptTTL = 2 * time.Hour
	indexKernelMaxAttemptBytes    = 64 << 20
)

type indexKernelHolder = cachetracker.Holder[*production.Provider]
type indexKernelAttempt = cachetracker.Attempt[*production.Provider]

// These sequential tests retain the exact indexes supplied to the real actor.
// Settings are constructor inputs, never a mutable mirror of runtime state.
type cacheIndexKernelFixture struct {
	*cachetracker.Tracker[*production.Provider]
	config cachetracker.Config[*production.Provider]
}

func newCacheIndexKernelFixture(settings cachetracker.Settings, configure ...func(*cachetracker.Config[*production.Provider])) *cacheIndexKernelFixture {
	generation := &cacheplan.Generation{}
	fences := cacheindex.NewRecords[cachetracker.FenceKey, cachetracker.FenceRecord]()
	config := cachetracker.Config[*production.Provider]{
		Settings: settings, Generation: generation,
		Holders:     cacheindex.NewHolders[indexKernelHolder](),
		Attempts:    cacheindex.NewRecords[string, indexKernelAttempt](),
		HolderOrder: cacheindex.NewHolderOrder(), AttemptOrder: cacheindex.NewAttemptOrder(), TerminalOrder: cacheindex.NewAttemptOrder(),
		HolderProviders:  cacheindex.NewProviderIndex[*cacheindex.Entry[cacheindex.HolderRef]](),
		AttemptProviders: cacheindex.NewProviderIndex[*cacheindex.Entry[cacheindex.AttemptRef]](),
		Sequences:        cacheindex.NewRecords[cachetracker.SequenceKey, uint64](),
		Proofs:           cachetracker.NewProofs(generation, fences),
		AttemptBudget:    cachetracker.NewAttemptBudget(indexKernelMaxAttemptBytes),
	}
	for _, apply := range configure {
		apply(&config)
	}
	return &cacheIndexKernelFixture{Tracker: cachetracker.New(config), config: config}
}

func indexKernelTestHolder(tracker *cacheIndexKernelFixture, provider, tier string, at time.Time) indexKernelHolder {
	return indexKernelHolder{ProviderID: provider, UpdatedAt: at, ExpiresAt: at.Add(tracker.ReceiptTTL(tier))}
}

func (t *cacheIndexKernelFixture) sizingTestHas(key, provider string) bool {
	_, held := t.config.Holders.Bucket(key).Load(provider)
	ordered := t.config.HolderOrder.Load(cacheindex.HolderRef{Key: key, ProviderID: provider}) != nil
	return held && ordered
}

func (t *cacheIndexKernelFixture) indexSizes() (holders, holderHeap, attempts, attemptHeap int) {
	return t.config.Holders.Len(), t.config.HolderOrder.Len(), t.config.Attempts.Len(), t.config.AttemptOrder.Len()
}

func indexKernelMetrics(tracker *cacheIndexKernelFixture) struct {
	Added   uint64
	Removed map[string]uint64
} {
	added, removed := tracker.HolderLifecycle(nil)
	return struct {
		Added   uint64
		Removed map[string]uint64
	}{added, removed}
}

func fillIndexKernelHolders(tracker *cacheIndexKernelFixture, count int, updatedAt time.Time) {
	for i := 0; i < count; i++ {
		at := updatedAt.Add(time.Duration(i) * time.Microsecond)
		tracker.UpsertHolderLocked(fmt.Sprintf("filler-%036d", i), indexKernelHolder{
			ProviderID:         "provider-" + strconv.Itoa(i%512),
			ModelID:            "model",
			ModelAggregateHash: fmt.Sprintf("%064x", i),
			PromptContractID:   fmt.Sprintf("%064x", i),
			CacheEpoch:         fmt.Sprintf("%036d", i),
			Anchor: protocol.PrefixCacheAnchor{
				TokenCount: int(promptcontract.BlockSize),
				ChainHash:  fmt.Sprintf("%064x", i+1),
			},
			StageMs:   120,
			UpdatedAt: at,
			ExpiresAt: at.Add(tracker.config.TTL),
		})
	}
}
