package cachepersist

import (
	"time"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// MarkHolderUpsert keeps the newest desired row, rejecting receipts sampled
// before an invalidation. Nil-safe; the registry decides what is persistable.
func (p *Persister) MarkHolderUpsert(rec crs.HolderRecord) {
	if p == nil {
		return
	}
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	k := rec.HolderKey()
	if p.tombstonedLocked(k, rec.UpdatedAt) {
		p.queue.Counters.StaleUpserts++
		return
	}
	previous, exists := p.queue.HolderUpserts[k]
	if exists {
		rec = crs.Later(previous.Record, rec)
	} else if len(p.queue.HolderUpserts) >= p.queue.DirtyCap {
		// Keep an outstanding delete when the replacement cannot be queued.
		p.queue.Counters.DroppedDirty++
		return
	}
	if deletion, pending := p.queue.HolderDeletes[k]; pending {
		// A fresh receipt supersedes the write, but older receipts must still
		// see its invalidation fence after this upsert is acknowledged.
		p.rememberDeleteLocked(k, deletion.DeletedAt)
	}
	delete(p.queue.HolderDeletes, k)
	p.queue.Revision++
	p.queue.HolderUpserts[k] = cachequeue.HolderChange{Record: rec, Revision: p.queue.Revision}
}

// MarkHolderDelete records the latest invalidation and discards any parked
// copy it outranks. Delete overflow invalidates the durable copy and rejects
// evidence at or before the latest decision released, including late receipts.
func (p *Persister) MarkHolderDelete(k crs.HolderKey, decidedAt time.Time) {
	if p == nil {
		return
	}
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	previous, exists := p.queue.HolderDeletes[k]
	if exists && previous.DeletedAt.After(decidedAt) {
		decidedAt = previous.DeletedAt
	}
	if retained := p.queue.RecentDeletes[k]; retained.After(decidedAt) {
		decidedAt = retained
	}
	if decidedAt.After(p.queue.DeleteHighWater) {
		p.queue.DeleteHighWater = decidedAt
	}
	if !exists && len(p.queue.HolderDeletes) >= p.queue.DirtyCap {
		p.requireResetLocked()
	}
	delete(p.queue.HolderUpserts, k)
	p.queue.Revision++
	p.queue.HolderDeletes[k] = cachequeue.DeleteChange{DeletedAt: decidedAt, Revision: p.queue.Revision}
	p.dropParkedIfOutrankedLocked(k, decidedAt)
}

// MarkDemand coalesces observations within the TTL-bounded granularity.
func (p *Persister) MarkDemand(keys []string, now time.Time) {
	if p == nil || len(keys) == 0 {
		return
	}
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	for _, key := range keys {
		if last, ok := p.queue.DemandPersisted[key]; ok && now.Sub(last) < p.queue.DemandGranularity {
			continue
		}
		previous, exists := p.queue.DemandTouched[key]
		if exists && !now.After(previous.SeenAt) {
			continue
		}
		if !exists && len(p.queue.DemandTouched) >= p.queue.DirtyCap {
			p.queue.Counters.DroppedDirty++
			continue
		}
		p.queue.Revision++
		p.queue.DemandTouched[key] = cachequeue.DemandChange{SeenAt: now, Revision: p.queue.Revision}
	}
}
