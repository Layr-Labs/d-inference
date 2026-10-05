// Package cachequeue owns bounded cache-routing mutation snapshots and indexed
// pruning. The persistence pipeline applies receipts and acknowledgements under
// Mu; store IO never holds this leaf lock.
package cachequeue

import (
	"sync"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

const (
	DemandPersistGranularity = time.Minute
	DemandFlushRows          = 5000
	HolderFlushRows          = 5000
	PruneBatchRows           = 5000
)

// Queue is shared by the receipt producer and store writer. Every mutable field
// is protected by Mu, including multi-index mutations and the overflow fence.
type Queue struct {
	MaxPending int
	DirtyCap   int
	Mu         sync.Mutex

	// One desired mutation per identity, indexed by write kind so snapshots
	// visit only their bounded batch, even when one kind has a large backlog.
	// Revisions never reset, so an old acknowledgement cannot clear new work.
	HolderUpserts     map[crs.HolderKey]HolderChange
	HolderDeletes     map[crs.HolderKey]DeleteChange
	Revision          uint64
	DemandTouched     map[string]DemandChange
	DemandGranularity time.Duration
	DemandPersisted   map[string]time.Time

	// Deletes remain fences after acknowledgement or supersession, for one
	// TTL and within retentionLimit. Both orders hold one entry per key.
	RecentDeletes  map[crs.HolderKey]time.Time
	RecentOrder    TimeOrder
	RetentionLimit int
	Pending        map[string]map[crs.HolderKey]crs.HolderRecord
	ParkedBucket   map[crs.HolderKey]string
	ParkedExpiry   TimeOrder
	PendingCount   int
	Counters       Counters

	// Store writes wait until restore establishes the key generation.
	Ready bool
	// The sequence fences in-flight batches. discardBefore fences delayed
	// receipts and parked rows after an overflow releases per-key decisions.
	ResetPending    bool
	OverflowSeq     uint64
	DeleteHighWater time.Time
	DiscardBefore   time.Time
	ResetWake       chan struct{}
}

func New(maxPending int, demandTTL time.Duration) *Queue {
	if maxPending <= 0 {
		maxPending = 250_000
	}
	granularity := DemandPersistGranularity
	if demandTTL > 0 && demandTTL/4 < granularity {
		granularity = demandTTL / 4
	}
	return &Queue{
		MaxPending: maxPending, DirtyCap: 4 * maxPending,
		DemandGranularity: granularity,
		HolderUpserts:     make(map[crs.HolderKey]HolderChange),
		HolderDeletes:     make(map[crs.HolderKey]DeleteChange),
		DemandTouched:     make(map[string]DemandChange),
		DemandPersisted:   make(map[string]time.Time),
		RecentDeletes:     make(map[crs.HolderKey]time.Time),
		RetentionLimit:    max(maxPending, HolderFlushRows),
		Pending:           make(map[string]map[crs.HolderKey]crs.HolderRecord),
		ParkedBucket:      make(map[crs.HolderKey]string),
		ResetWake:         make(chan struct{}, 1),
	}
}

type Counters struct {
	RestoredHolders int
	RestoredDemand  int
	BoundHolders    uint64
	DroppedPending  uint64
	Flushes         uint64
	FlushErrors     uint64
	RowsWritten     uint64
	RowsDeleted     uint64
	DroppedDirty    uint64
	OverflowResets  uint64
	StaleUpserts    uint64
	LastFlushMs     int64
	LastFlushAt     time.Time
	KeyRotated      bool
}
