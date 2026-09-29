package cachepersist

import "time"

type counters struct {
	restoredHolders int
	restoredDemand  int
	boundHolders    uint64
	droppedPending  uint64
	flushes         uint64
	flushErrors     uint64
	rowsWritten     uint64
	rowsDeleted     uint64
	droppedDirty    uint64
	lastFlushMs     int64
	lastFlushAt     time.Time
	keyRotated      bool
}

// Status is the aggregate, content-free view exposed on the cache status
// lifecycle block.
type Status struct {
	Enabled         bool   `json:"enabled"`
	RestoredHolders int    `json:"restored_holders"`
	RestoredDemand  int    `json:"restored_demand"`
	PendingHolders  int    `json:"pending_holders"`
	BoundHolders    uint64 `json:"bound_holders"`
	DroppedPending  uint64 `json:"dropped_pending"`
	Flushes         uint64 `json:"flushes"`
	FlushErrors     uint64 `json:"flush_errors"`
	RowsWritten     uint64 `json:"rows_written"`
	RowsDeleted     uint64 `json:"rows_deleted"`
	DroppedDirty    uint64 `json:"dropped_dirty"`
	LastFlushMs     int64  `json:"last_flush_ms"`
	LastFlushAt     string `json:"last_flush_at,omitempty"`
	// Ready is false until the restore has established the key generation;
	// nothing is written before that (the registry retries every flush tick).
	Ready bool `json:"ready"`
	// KeyRotated is true when this boot found a recorded cache-key generation
	// that differs from its own and reset the tables instead of restoring
	// them; a first boot with nothing recorded does not count.
	KeyRotated bool `json:"key_rotated"`
}

// Status snapshots the counters. A nil persister reports Enabled=false.
func (p *Persister) Status() Status {
	if p == nil {
		return Status{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	c := p.counters
	s := Status{
		Enabled: true, RestoredHolders: c.restoredHolders, RestoredDemand: c.restoredDemand,
		PendingHolders: p.pendingCount, BoundHolders: c.boundHolders, DroppedPending: c.droppedPending,
		Flushes: c.flushes, FlushErrors: c.flushErrors, RowsWritten: c.rowsWritten, RowsDeleted: c.rowsDeleted,
		DroppedDirty: c.droppedDirty, LastFlushMs: c.lastFlushMs, KeyRotated: c.keyRotated, Ready: p.ready,
	}
	if !c.lastFlushAt.IsZero() {
		s.LastFlushAt = c.lastFlushAt.UTC().Format(time.RFC3339)
	}
	return s
}
