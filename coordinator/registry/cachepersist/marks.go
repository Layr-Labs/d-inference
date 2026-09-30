package cachepersist

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// MarkHolderUpsert keeps the newest desired row, rejecting receipts sampled
// before an invalidation. Nil-safe; the registry decides what is persistable.
func (p *Persister) MarkHolderUpsert(rec crs.HolderRecord) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	k := rec.HolderKey()
	if p.tombstonedLocked(k, rec.UpdatedAt) {
		p.counters.staleUpserts++
		return
	}
	previous, exists := p.holderUpserts[k]
	if exists {
		rec = crs.Later(previous.record, rec)
	} else if len(p.holderUpserts) >= p.dirtyCap {
		// Keep an outstanding delete when the replacement cannot be queued.
		p.counters.droppedDirty++
		return
	}
	if deletion, pending := p.holderDeletes[k]; pending {
		// A fresh receipt supersedes the write, but older receipts must still
		// see its invalidation fence after this upsert is acknowledged.
		p.rememberDeleteLocked(k, deletion.deletedAt)
	}
	delete(p.holderDeletes, k)
	p.revision++
	p.holderUpserts[k] = holderChange{record: rec, revision: p.revision}
}

// MarkHolderDelete records the latest invalidation and discards any parked
// copy it outranks. Delete overflow invalidates the durable copy and rejects
// evidence at or before the latest decision released, including late receipts.
func (p *Persister) MarkHolderDelete(k crs.HolderKey, decidedAt time.Time) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	previous, exists := p.holderDeletes[k]
	if exists && previous.deletedAt.After(decidedAt) {
		decidedAt = previous.deletedAt
	}
	if retained := p.recentDeletes[k]; retained.After(decidedAt) {
		decidedAt = retained
	}
	if decidedAt.After(p.deleteHighWater) {
		p.deleteHighWater = decidedAt
	}
	if !exists && len(p.holderDeletes) >= p.dirtyCap {
		p.requireResetLocked()
	}
	delete(p.holderUpserts, k)
	p.revision++
	p.holderDeletes[k] = deleteChange{deletedAt: decidedAt, revision: p.revision}
	p.dropParkedIfOutrankedLocked(k, decidedAt)
}

// MarkDemand coalesces observations within the TTL-bounded granularity.
func (p *Persister) MarkDemand(keys []string, now time.Time) {
	if p == nil || len(keys) == 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, key := range keys {
		if last, ok := p.demandPersisted[key]; ok && now.Sub(last) < p.demandGranularity {
			continue
		}
		previous, exists := p.demandTouched[key]
		if exists && !now.After(previous.seenAt) {
			continue
		}
		if !exists && len(p.demandTouched) >= p.dirtyCap {
			p.counters.droppedDirty++
			continue
		}
		p.revision++
		p.demandTouched[key] = demandChange{seenAt: now, revision: p.revision}
	}
}
