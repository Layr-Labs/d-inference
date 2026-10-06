package cachepersist

import (
	"time"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"

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
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	pk := pendingKey(rec.CacheEpoch, rec.ModelID)
	hk := rec.HolderKey()
	// Evidence a delete already decided outranks is not worth parking.
	if p.tombstonedLocked(hk, rec.UpdatedAt) {
		p.queue.Counters.DroppedPending++
		return
	}
	// Overlapping sessions of one machine park the same durable row more
	// than once; one parked copy per (key, epoch), the newer evidence.
	if parked, ok := p.queue.Pending[pk][hk]; ok {
		merged := crs.Later(parked, rec)
		p.queue.Pending[pk][hk] = merged
		if !merged.ExpiresAt.Equal(parked.ExpiresAt) {
			setTime(&p.queue.ParkedExpiry, hk, merged.ExpiresAt)
		}
		return
	}
	if p.queue.PendingCount >= p.queue.MaxPending {
		p.queue.Counters.DroppedPending++
		return
	}
	p.addParkedLocked(pk, rec)
}

// addParkedLocked inserts a parked row into its bucket, the identity index
// and the expiry order. Called with p.queue.Mu held; the caller has checked the cap.
func (p *Persister) addParkedLocked(pk string, rec crs.HolderRecord) {
	bucket := p.queue.Pending[pk]
	if bucket == nil {
		bucket = make(map[crs.HolderKey]crs.HolderRecord)
		p.queue.Pending[pk] = bucket
	}
	hk := rec.HolderKey()
	bucket[hk] = rec
	p.queue.ParkedBucket[hk] = pk
	p.queue.PendingCount++
	setTime(&p.queue.ParkedExpiry, hk, rec.ExpiresAt)
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
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	pk := pendingKey(epoch, model)
	bucket := p.queue.Pending[pk]
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
		p.queue.RemoveParked(pk, hk)
	}
	if len(p.queue.Pending[pk]) == 0 {
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
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	return p.queue.PendingCount > 0
}

// AddBound records the outcome of a Take: rows that became live holders, and
// rows the registry dropped as expired, mismatched, or parked for a
// capability that no longer exists.
func (p *Persister) AddBound(bound, dropped uint64) {
	if p == nil {
		return
	}
	p.queue.Mu.Lock()
	p.queue.Counters.BoundHolders += bound
	p.queue.Counters.DroppedPending += dropped
	p.queue.Mu.Unlock()
}

// pruneBatchRows bounds the rows one prune lock hold examines, parked rows
// and retained decisions alike.
const pruneBatchRows = cachequeue.PruneBatchRows

// prunePendingChunked drops expired parked rows in bounded chunks, releasing
// p.queue.Mu between them, so a receipt holding the tracker lock (and behind it
// the request path) never waits behind a full scan.
func (p *Persister) prunePendingChunked(now time.Time) {
	for {
		p.queue.Mu.Lock()
		more := p.queue.PrunePendingBatch(now, pruneBatchRows)
		p.queue.Mu.Unlock()
		if !more {
			return
		}
	}
}
