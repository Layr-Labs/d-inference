package cachepersist

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// pendingKey groups parked rows by the provider root and the model, so binding
// one capability never consumes another model's rows under the same epoch.
func pendingKey(epoch, model string) string { return epoch + "\x00" + model }

// Park keeps a holder whose provider disconnected until that provider's epoch
// and model come back. Bounded by maxPending; expired rows are dropped at
// bind (by the registry) and at prune.
func (p *Persister) Park(rec crs.HolderRecord) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	pk := pendingKey(rec.CacheEpoch, rec.ModelID)
	hk := rec.HolderKey()
	// Evidence a delete already decided outranks is not worth parking.
	if p.tombstonedLocked(hk, rec.UpdatedAt) {
		p.counters.droppedPending++
		return
	}
	// Overlapping sessions of one machine park the same durable row more
	// than once; one parked copy per (key, epoch), the newer evidence.
	if parked, ok := p.pending[pk][hk]; ok {
		p.pending[pk][hk] = crs.Later(parked, rec)
		return
	}
	if p.pendingCount >= p.maxPending {
		p.counters.droppedPending++
		return
	}
	p.addParkedLocked(pk, rec)
}

// addParkedLocked inserts a parked row into its bucket and the identity
// index. Called with p.mu held; the caller has checked the cap.
func (p *Persister) addParkedLocked(pk string, rec crs.HolderRecord) {
	bucket := p.pending[pk]
	if bucket == nil {
		bucket = make(map[crs.HolderKey]crs.HolderRecord)
		p.pending[pk] = bucket
	}
	hk := rec.HolderKey()
	bucket[hk] = rec
	p.parkedBucket[hk] = pk
	p.pendingCount++
}

// removeParkedLocked removes one parked row from its bucket and the identity
// index, dropping the bucket when it empties. Called with p.mu held.
func (p *Persister) removeParkedLocked(pk string, hk crs.HolderKey) {
	bucket := p.pending[pk]
	delete(bucket, hk)
	delete(p.parkedBucket, hk)
	p.pendingCount--
	if len(bucket) == 0 {
		delete(p.pending, pk)
	}
}

// Take pops up to limit rows parked under one (cache epoch, model) (limit
// <= 0 takes them all) and reports whether any remain. The caller binds the
// ones that match its capability, or settles their durable rows when the
// capability is gone, and reports the outcome with AddBound. A bounded take
// lets the registry bind a large bucket in chunks, releasing its tracker
// lock in between.
func (p *Persister) Take(epoch, model string, limit int) ([]crs.HolderRecord, bool) {
	if p == nil {
		return nil, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	pk := pendingKey(epoch, model)
	bucket := p.pending[pk]
	if len(bucket) == 0 {
		return nil, false
	}
	n := len(bucket)
	if limit > 0 && limit < n {
		n = limit
	}
	rows := make([]crs.HolderRecord, 0, n)
	for hk, rec := range bucket {
		if len(rows) == n {
			break
		}
		rows = append(rows, rec)
		p.removeParkedLocked(pk, hk)
	}
	if len(p.pending[pk]) == 0 {
		return rows, false
	}
	return rows, true
}

// HasPending reports whether any restored or parked rows await a provider.
// It is the cheap check a capability apply makes before taking the tracker
// lock for a bind.
func (p *Persister) HasPending() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingCount > 0
}

// AddBound records the outcome of a Take: rows that became live holders, and
// rows the registry dropped as expired, mismatched, or parked for a
// capability that no longer exists.
func (p *Persister) AddBound(bound, dropped uint64) {
	if p == nil {
		return
	}
	p.mu.Lock()
	p.counters.boundHolders += bound
	p.counters.droppedPending += dropped
	p.mu.Unlock()
}

// prunePending drops parked rows past their own expiry: their provider never
// came back in time.
func (p *Persister) prunePending(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingLocked(now)
}

func (p *Persister) prunePendingLocked(now time.Time) {
	for pk, bucket := range p.pending {
		for hk, rec := range bucket {
			if !rec.ExpiresAt.After(now) {
				p.removeParkedLocked(pk, hk)
				p.counters.droppedPending++
			}
		}
	}
}
