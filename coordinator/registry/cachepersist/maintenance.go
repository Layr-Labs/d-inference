package cachepersist

import (
	"context"
	"time"
)

// Prune removes expired rows from the store, drops expired parked rows and
// forgets the persisted-demand dedupe map, which is only a write-rate
// optimisation and may be reset freely.
func (p *Persister) Prune(ctx context.Context, now time.Time, ttl time.Duration) {
	if p == nil {
		return
	}
	// Parked rows are in-process state and expire whether or not the store
	// is reachable; dropping them never waits for the restore. A written
	// tombstone outranks older parked evidence for one TTL, after which any
	// such row has expired on its own. Both run in bounded chunks: a receipt
	// holding the tracker lock waits on p.mu, and requests on the tracker
	// lock.
	p.prunePendingChunked(now)
	p.forgetDecisionsChunked(now, ttl)
	if !p.Ready() {
		return
	}
	if _, err := p.store.PruneCacheRoutingState(ctx, now, ttl, now.Add(-ttl)); err != nil && ctx.Err() == nil {
		p.logger.Warn("cache routing persistence prune failed", "error", err)
	}
	p.mu.Lock()
	p.demandPersisted = make(map[string]time.Time)
	p.mu.Unlock()
}
