package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
)

type Settings struct {
	TTL                                 time.Duration
	MaxHolders, MaxEntries, MaxAttempts int
}

type Config[P comparable] struct {
	Settings
	Now              func() time.Time
	Generation       *cacheplan.Generation
	Holders          *cacheindex.Holders[Holder[P]]
	Attempts         *cacheindex.Records[string, Attempt[P]]
	HolderOrder      *cacheindex.Order[cacheindex.HolderRef, cacheindex.HolderRef]
	AttemptOrder     *cacheindex.Order[cacheindex.AttemptRef, string]
	TerminalOrder    *cacheindex.Order[cacheindex.AttemptRef, string]
	HolderProviders  *cacheindex.ProviderIndex[*cacheindex.Entry[cacheindex.HolderRef]]
	AttemptProviders *cacheindex.ProviderIndex[*cacheindex.Entry[cacheindex.AttemptRef]]
	Sequences        *cacheindex.Records[SequenceKey, uint64]
	Proofs           *Proofs
	AttemptBudget    *AttemptBudget
}

// Tracker owns receipt evidence. The controller serializes every operation
// under its original Registry -> Provider -> receipt-controller mutex order.
// Retained index dependencies are the actual indexes, never state mirrors.
type Tracker[P comparable] struct {
	zero                                         P
	generation                                   *cacheplan.Generation
	ttl                                          time.Duration
	maxHolders, maxEntries, maxAttempts          int
	lastSweep                                    time.Time
	sweepBacklog                                 bool
	persister                                    *cachepersist.Persister
	restoring                                    bool
	holders                                      *cacheindex.Holders[Holder[P]]
	attempts                                     *cacheindex.Records[string, Attempt[P]]
	holderOrder                                  *cacheindex.Order[cacheindex.HolderRef, cacheindex.HolderRef]
	attemptOrder                                 *cacheindex.Order[cacheindex.AttemptRef, string]
	terminalOrder                                *cacheindex.Order[cacheindex.AttemptRef, string]
	holdersByProvider                            *cacheindex.ProviderIndex[*cacheindex.Entry[cacheindex.HolderRef]]
	attemptsByProvider                           *cacheindex.ProviderIndex[*cacheindex.Entry[cacheindex.AttemptRef]]
	v2Sequences                                  *cacheindex.Records[SequenceKey, uint64]
	proofs                                       *Proofs
	attemptBudget                                *AttemptBudget
	attemptBudgetRefused, attemptGraceReclaimed  uint64
	holderAdded                                  uint64
	holderRemoved                                map[string]uint64
	ssdLookups, ssdHits, ssdMisses, ssdDonations uint64
	donationOutcomes                             map[string]uint64
	clock                                        func() time.Time
}

type Binding[P comparable] struct {
	ProviderID string
	Provider   P
}

type RemovalReason string

const (
	RemovalTTL                         RemovalReason = "ttl"
	RemovalDisconnect                  RemovalReason = "disconnect"
	RemovalEpochChange                 RemovalReason = "epoch_change"
	RemovalCapabilityChange            RemovalReason = "capability_change"
	RemovalProofMismatch               RemovalReason = "proof_mismatch"
	RemovalMissInvalidation            RemovalReason = "miss_invalidation"
	RemovalCapacityEviction            RemovalReason = "capacity_eviction"
	RemovalShorterHit                  RemovalReason = "shorter_hit"
	MaxSweepRemovals                                 = 1024
	SweepInterval                                    = 30 * time.Second
	MemoryTTL                                        = 30 * time.Second
	BindChunkRows                                    = 1000
	cacheHolderRemovalTTL                            = RemovalTTL
	cacheHolderRemovalDisconnect                     = RemovalDisconnect
	cacheHolderRemovalMissInvalidation               = RemovalMissInvalidation
	cacheHolderRemovalCapacityEviction               = RemovalCapacityEviction
	cacheHolderRemovalShorterHit                     = RemovalShorterHit
	cacheRoutingMaxSweepRemovals                     = MaxSweepRemovals
	cacheRoutingSweepInterval                        = SweepInterval
	cacheRoutingMemoryTTL                            = MemoryTTL
	bindChunkRows                                    = BindChunkRows
)

func New[P comparable](config Config[P]) *Tracker[P] {
	return &Tracker[P]{generation: config.Generation, ttl: config.TTL,
		maxHolders: config.MaxHolders, maxEntries: config.MaxEntries, maxAttempts: config.MaxAttempts,
		clock: config.Now, holders: config.Holders, attempts: config.Attempts,
		holderOrder: config.HolderOrder, attemptOrder: config.AttemptOrder, terminalOrder: config.TerminalOrder,
		holdersByProvider: config.HolderProviders, attemptsByProvider: config.AttemptProviders,
		v2Sequences: config.Sequences, proofs: config.Proofs, attemptBudget: config.AttemptBudget,
		holderRemoved: make(map[string]uint64), donationOutcomes: make(map[string]uint64)}
}

func (t *Tracker[P]) now() time.Time {
	if t.clock != nil {
		return t.clock()
	}
	return time.Now()
}

func (t *Tracker[P]) AttachPersistence(persister *cachepersist.Persister) { t.persister = persister }

// HolderLifecycle emits detached aggregate lifecycle counters for a scrape.
func (t *Tracker[P]) HolderLifecycle(reasons []string) (uint64, map[string]uint64) {
	removed := make(map[string]uint64, len(reasons))
	for _, reason := range reasons {
		removed[reason] = 0
	}
	for reason, count := range t.holderRemoved {
		removed[reason] = count
	}
	return t.holderAdded, removed
}

// ContinueSweep bounds the controller's repeated status passes. The caller
// releases its mutex between passes so a mass expiry cannot monopolize it.
func (t *Tracker[P]) ContinueSweep(pass int) bool {
	limit := (t.maxEntries+t.maxAttempts)/cacheRoutingMaxSweepRemovals + 1
	return t.sweepBacklog && pass < limit
}
