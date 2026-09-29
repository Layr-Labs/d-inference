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
	if p.pendingCount < p.maxPending {
		pk := pendingKey(rec.CacheEpoch, rec.ModelID)
		p.pending[pk] = append(p.pending[pk], rec)
		p.pendingCount++
	} else {
		p.counters.droppedPending++
	}
	p.mu.Unlock()
}

// Take pops the rows parked under one (cache epoch, model). The caller binds
// the ones that match its capability, or settles their durable rows when the
// capability is gone, and reports the outcome with AddBound.
func (p *Persister) Take(epoch, model string) []crs.HolderRecord {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	pk := pendingKey(epoch, model)
	rows := p.pending[pk]
	if len(rows) == 0 {
		return nil
	}
	delete(p.pending, pk)
	p.pendingCount -= len(rows)
	return rows
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
	for pk, rows := range p.pending {
		kept := rows[:0]
		for _, rec := range rows {
			if rec.ExpiresAt.After(now) {
				kept = append(kept, rec)
			} else {
				p.counters.droppedPending++
				p.pendingCount--
			}
		}
		if len(kept) == 0 {
			delete(p.pending, pk)
		} else {
			p.pending[pk] = kept
		}
	}
}
