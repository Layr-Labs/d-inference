package cachequeue

import (
	"container/heap"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// removeTime drops a key's entry, if it has one.
func removeTime(h *TimeOrder, key crs.HolderKey) {
	if i, ok := h.Pos[key]; ok {
		heap.Remove(h, i)
	}
}

// removeParkedLocked removes one parked row from its bucket, the identity
// index and the expiry order, dropping the bucket when it empties. Called
// with p.Mu held.
func (p *Queue) RemoveParked(pk string, hk crs.HolderKey) {
	bucket := p.Pending[pk]
	delete(bucket, hk)
	delete(p.ParkedBucket, hk)
	removeTime(&p.ParkedExpiry, hk)
	p.PendingCount--
	if len(bucket) == 0 {
		delete(p.Pending, pk)
	}
}

// prunePendingBatchLocked drops up to limit expired parked rows (limit <= 0:
// no bound), soonest expiry first, and reports whether expired rows may
// remain. The expiry order holds exactly one entry per parked row, so each
// pop is one drop. Called with p.Mu held.
func (p *Queue) PrunePendingBatch(now time.Time, limit int) bool {
	dropped := 0
	for {
		top, ok := p.ParkedExpiry.Soonest()
		if !ok || top.At.After(now) {
			return false
		}
		if limit > 0 && dropped >= limit {
			return true
		}
		dropped++
		pk, ok := p.ParkedBucket[top.Key]
		if !ok {
			// Unreachable while the one-entry-per-row invariant holds; an
			// orphan entry is discarded rather than miscounting the set.
			removeTime(&p.ParkedExpiry, top.Key)
			continue
		}
		p.RemoveParked(pk, top.Key)
		p.Counters.DroppedPending++
	}
}

// forgetDecisionLocked removes one retained decision from the map and the
// order. Called with p.Mu held.
func (p *Queue) ForgetDecision(k crs.HolderKey) {
	delete(p.RecentDeletes, k)
	removeTime(&p.RecentOrder, k)
}

// forgetDecisionsBatchLocked forgets up to limit decisions older than the
// TTL (limit <= 0: no bound), oldest first, and reports whether older ones
// may remain. Called with p.Mu held.
func (p *Queue) ForgetDecisionsBatch(now time.Time, ttl time.Duration, limit int) bool {
	forgotten := 0
	for {
		oldest, ok := p.RecentOrder.Soonest()
		if !ok || now.Sub(oldest.At) < ttl {
			return false
		}
		if limit > 0 && forgotten >= limit {
			return true
		}
		forgotten++
		p.ForgetDecision(oldest.Key)
	}
}

// soonest returns the entry with the earliest time.
func (h *TimeOrder) Soonest() (TimedKey, bool) {
	if len(h.Entries) == 0 {
		return TimedKey{}, false
	}
	return h.Entries[0], true
}
