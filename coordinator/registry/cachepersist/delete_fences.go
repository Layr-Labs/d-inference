package cachepersist

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// dropParkedIfOutrankedLocked discards the parked copy of a row whose
// evidence is not newer than a delete decided at decidedAt. Called with p.mu
// held.
func (p *Persister) dropParkedIfOutrankedLocked(k crs.HolderKey, decidedAt time.Time) {
	pk, ok := p.parkedBucket[k]
	if !ok {
		return
	}
	if rec, ok := p.pending[pk][k]; ok && !rec.UpdatedAt.After(decidedAt) {
		p.removeParkedLocked(pk, k)
		p.counters.droppedPending++
	}
}

// tombstonedLocked is Tombstoned with p.mu held.
func (p *Persister) tombstonedLocked(k crs.HolderKey, updatedAt time.Time) bool {
	// A reset forgets per-key decisions but keeps their conservative cutoff.
	if !p.discardBefore.IsZero() && !updatedAt.After(p.discardBefore) {
		return true
	}
	// Ties go to the delete, as in MarkHolderUpsert.
	if change, pending := p.holderDeletes[k]; pending && !updatedAt.After(change.deletedAt) {
		return true
	}
	decided, ok := p.recentDeletes[k]
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
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.tombstonedLocked(k, updatedAt)
}

// rememberDeleteLocked records a delete decision for Tombstoned, bounded by
// the holder budget: beyond the limit the oldest decisions are forgotten
// first, by decision time (the TTL bound is applied by Prune). A key decided
// again moves to its new time. Called with p.mu held.
func (p *Persister) rememberDeleteLocked(k crs.HolderKey, at time.Time) {
	if cur, present := p.recentDeletes[k]; present && !at.After(cur) {
		return
	}
	p.recentDeletes[k] = at
	p.recentOrder.set(k, at)
	for len(p.recentDeletes) > p.retentionLimit {
		oldest, ok := p.recentOrder.soonest()
		if !ok {
			break
		}
		p.forgetDecisionLocked(oldest.key)
	}
}

// forgetDecisionLocked removes one retained decision from the map and the
// order. Called with p.mu held.
func (p *Persister) forgetDecisionLocked(k crs.HolderKey) {
	delete(p.recentDeletes, k)
	p.recentOrder.remove(k)
}

// forgetDecisionsChunked forgets the delete decisions older than the TTL in
// bounded chunks, releasing p.mu between them, so a receipt holding the
// tracker lock (and behind it the request path) never waits behind a scan
// of the whole retention set.
func (p *Persister) forgetDecisionsChunked(now time.Time, ttl time.Duration) {
	for {
		p.mu.Lock()
		more := p.forgetDecisionsBatchLocked(now, ttl, pruneBatchRows)
		p.mu.Unlock()
		if !more {
			return
		}
	}
}

// forgetDecisionsBatchLocked forgets up to limit decisions older than the
// TTL (limit <= 0: no bound), oldest first, and reports whether older ones
// may remain. Called with p.mu held.
func (p *Persister) forgetDecisionsBatchLocked(now time.Time, ttl time.Duration, limit int) bool {
	forgotten := 0
	for {
		oldest, ok := p.recentOrder.soonest()
		if !ok || now.Sub(oldest.at) < ttl {
			return false
		}
		if limit > 0 && forgotten >= limit {
			return true
		}
		forgotten++
		p.forgetDecisionLocked(oldest.key)
	}
}
