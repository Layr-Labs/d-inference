package cachepersist

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// dropParkedIfOutrankedLocked discards the parked copy of a row whose
// evidence is not newer than a delete decided at decidedAt. Called with p.queue.Mu
// held.
func (p *Persister) dropParkedIfOutrankedLocked(k crs.HolderKey, decidedAt time.Time) {
	pk, ok := p.queue.ParkedBucket[k]
	if !ok {
		return
	}
	if rec, ok := p.queue.Pending[pk][k]; ok && !rec.UpdatedAt.After(decidedAt) {
		p.queue.RemoveParked(pk, k)
		p.queue.Counters.DroppedPending++
	}
}

// tombstonedLocked is Tombstoned with p.queue.Mu held.
func (p *Persister) tombstonedLocked(k crs.HolderKey, updatedAt time.Time) bool {
	// A reset forgets per-key decisions but keeps their conservative cutoff.
	if !p.queue.DiscardBefore.IsZero() && !updatedAt.After(p.queue.DiscardBefore) {
		return true
	}
	// Ties go to the delete, as in MarkHolderUpsert.
	if change, pending := p.queue.HolderDeletes[k]; pending && !updatedAt.After(change.DeletedAt) {
		return true
	}
	decided, ok := p.queue.RecentDeletes[k]
	return ok && !updatedAt.After(decided)
}

// Tombstoned reports whether a row whose evidence dates from updatedAt is
// outranked by a delete this run decided at or after that time: one still
// pending, written within the last TTL, or covered by the overflow cutoff.
// Such a row (loaded by
// a retried restore, or parked by an older session before the decision) must
// not bind.
func (p *Persister) Tombstoned(k crs.HolderKey, updatedAt time.Time) bool {
	if p == nil {
		return false
	}
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	return p.tombstonedLocked(k, updatedAt)
}

// rememberDeleteLocked records a delete decision for Tombstoned, bounded by
// the holder budget: beyond the limit the oldest decisions are forgotten
// first, by decision time (the TTL bound is applied by Prune). A key decided
// again moves to its new time. Called with p.queue.Mu held.
func (p *Persister) rememberDeleteLocked(k crs.HolderKey, at time.Time) {
	if cur, present := p.queue.RecentDeletes[k]; present && !at.After(cur) {
		return
	}
	p.queue.RecentDeletes[k] = at
	setTime(&p.queue.RecentOrder, k, at)
	for len(p.queue.RecentDeletes) > p.queue.RetentionLimit {
		oldest, ok := p.queue.RecentOrder.Soonest()
		if !ok {
			break
		}
		p.queue.ForgetDecision(oldest.Key)
	}
}

// forgetDecisionsChunked forgets the delete decisions older than the TTL in
// bounded chunks, releasing p.queue.Mu between them, so a receipt holding the
// tracker lock (and behind it the request path) never waits behind a scan
// of the whole retention set.
func (p *Persister) forgetDecisionsChunked(now time.Time, ttl time.Duration) {
	for {
		p.queue.Mu.Lock()
		more := p.queue.ForgetDecisionsBatch(now, ttl, pruneBatchRows)
		p.queue.Mu.Unlock()
		if !more {
			return
		}
	}
}
