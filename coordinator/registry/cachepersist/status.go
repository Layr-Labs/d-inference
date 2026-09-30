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
	overflowResets  uint64
	staleUpserts    uint64
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
	// DroppedDirty counts upserts and demand marks dropped at the dirty cap,
	// and pending upserts discarded by a delete-backlog overflow. Deletes
	// are covered by the durable reset instead: see OverflowResets.
	DroppedDirty uint64 `json:"dropped_dirty"`
	// OverflowResets counts the times the delete backlog outgrew its budget
	// during a store outage and the durable copy was discarded at the next
	// flush (or by the restore) instead of a delete being dropped, so a
	// restart after the reset lands never restores a row a miss or proof
	// mismatch invalidated.
	OverflowResets uint64 `json:"overflow_resets"`
	// StaleUpserts counts receipts whose evidence predated a delete this run
	// decided for the same row, or the conservative overflow cutoff. They
	// neither cancel a pending delete nor reach the store.
	StaleUpserts uint64 `json:"stale_upserts"`
	LastFlushMs  int64  `json:"last_flush_ms"`
	LastFlushAt  string `json:"last_flush_at,omitempty"`
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
		DroppedDirty: c.droppedDirty, OverflowResets: c.overflowResets, StaleUpserts: c.staleUpserts,
		LastFlushMs: c.lastFlushMs, KeyRotated: c.keyRotated, Ready: p.ready,
	}
	if !c.lastFlushAt.IsZero() {
		s.LastFlushAt = c.lastFlushAt.UTC().Format(time.RFC3339)
	}
	return s
}
