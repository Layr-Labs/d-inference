// Package cachepersist maintains a write-behind copy of the registry's exact
// SSD prefix-cache holder and demand indexes. Routing reads stay in memory;
// store IO runs outside registry locks. Restored holders park by cache epoch
// and model until a matching provider reconnects. Resident holders are never
// persisted.
package cachepersist

import (
	"log/slog"
	"sync"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

const (
	FlushInterval            = 5 * time.Second
	PruneInterval            = 5 * time.Minute
	DemandPersistGranularity = time.Minute
	DemandFlushRows          = 5_000
	HolderFlushRows          = 5_000
)

// Persister owns pending writes, parked holders and invalidation fences.
// mu is a leaf lock: it never acquires a registry or provider lock. flushMu
// serializes store writes, including a shutdown flush racing a periodic one.
type Persister struct {
	store       crs.Store
	logger      *slog.Logger
	maxPending  int
	dirtyCap    int
	fingerprint string
	flushMu     sync.Mutex
	mu          sync.Mutex

	// One desired mutation per identity, indexed by write kind so snapshots
	// visit only their bounded batch, even when one kind has a large backlog.
	// Revisions never reset, so an old acknowledgement cannot clear new work.
	holderUpserts     map[crs.HolderKey]holderChange
	holderDeletes     map[crs.HolderKey]deleteChange
	revision          uint64
	demandTouched     map[string]demandChange
	demandGranularity time.Duration
	demandPersisted   map[string]time.Time

	// Deletes remain fences after acknowledgement or supersession, for one
	// TTL and within retentionLimit. Both orders hold one entry per key.
	recentDeletes  map[crs.HolderKey]time.Time
	recentOrder    keyedTimeHeap
	retentionLimit int
	pending        map[string]map[crs.HolderKey]crs.HolderRecord
	parkedBucket   map[crs.HolderKey]string
	parkedExpiry   keyedTimeHeap
	pendingCount   int
	counters       counters

	// Store writes wait until restore establishes the key generation.
	ready bool
	// The sequence fences in-flight batches. discardBefore fences delayed
	// receipts and parked rows after an overflow releases per-key decisions.
	resetPending    bool
	overflowSeq     uint64
	deleteHighWater time.Time
	discardBefore   time.Time
	resetWake       chan struct{}
}

type Options struct {
	// MaxPending bounds parked holders. Each kind of pending write permits
	// four times that many entries; delete overflow resets the durable copy.
	MaxPending  int
	DemandTTL   time.Duration
	Fingerprint string
}

func New(st crs.Store, logger *slog.Logger, opts Options) *Persister {
	if logger == nil {
		logger = slog.Default()
	}
	maxPending := opts.MaxPending
	if maxPending <= 0 {
		maxPending = 250_000
	}
	granularity := DemandPersistGranularity
	if opts.DemandTTL > 0 && opts.DemandTTL/4 < granularity {
		granularity = opts.DemandTTL / 4
	}
	return &Persister{
		store: st, logger: logger, maxPending: maxPending, dirtyCap: 4 * maxPending,
		fingerprint: opts.Fingerprint, demandGranularity: granularity,
		holderUpserts:   make(map[crs.HolderKey]holderChange),
		holderDeletes:   make(map[crs.HolderKey]deleteChange),
		demandTouched:   make(map[string]demandChange),
		demandPersisted: make(map[string]time.Time),
		recentDeletes:   make(map[crs.HolderKey]time.Time),
		retentionLimit:  max(maxPending, HolderFlushRows),
		pending:         make(map[string]map[crs.HolderKey]crs.HolderRecord),
		parkedBucket:    make(map[crs.HolderKey]string),
		resetWake:       make(chan struct{}, 1),
	}
}

func (p *Persister) Wake() <-chan struct{} {
	if p == nil {
		return nil
	}
	return p.resetWake
}

func (p *Persister) Ready() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ready
}
