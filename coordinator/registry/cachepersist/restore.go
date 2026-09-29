package cachepersist

import (
	"context"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Restore loads the durable copy. If the store's rows were written under a
// different cache-key generation (the master key changed), both tables are
// reset first: their HMAC-derived keys can never match a request. Demand
// entries within ttl and not after now are returned, newest first up to
// maxDemand, for the registry to seed its index directly; the registry then
// reports the entries its index accepted with SeedDemandPersisted. Holder rows are loaded under the
// current ttl (the store clamps each row's expiry to UpdatedAt+ttl before it
// orders and caps, so a row written under a longer TTL neither outlives
// today's setting nor crowds a valid row out of the cap), longest-lived first
// up to maxHolders, and parked until the registry binds them to a provider
// whose capabilities match.
// restorePruneBudget bounds the prune Restore runs before loading, inside the
// registry's restore timeout.
const restorePruneBudget = 10 * time.Second

func (p *Persister) Restore(ctx context.Context, now time.Time, ttl time.Duration, maxHolders, maxDemand int) ([]crs.DemandRecord, error) {
	if p == nil {
		return nil, nil
	}
	stored, err := p.store.CacheRoutingKeyFingerprint(ctx)
	if err != nil {
		return nil, err
	}
	if stored != p.fingerprint {
		if err := p.store.ResetCacheRoutingState(ctx, p.fingerprint); err != nil {
			return nil, err
		}
		if stored == "" {
			p.logger.Info("cache routing persistence: recorded the cache-key generation; the durable copy starts empty")
		} else {
			p.logger.Warn("cache routing persistence: the cache master key changed; the durable copy was reset instead of restored")
		}
		p.mu.Lock()
		p.counters.keyRotated = stored != ""
		p.ready = true
		p.mu.Unlock()
		return nil, nil
	}
	// Expired rows, and rows another instance stamped ahead of this clock,
	// go before the load: a future-dated row is quarantined by the load, and
	// left in place its timestamp would outrank every receipt this run
	// writes for the same key until the clock caught up.
	// Bounded and non-fatal: after an outage longer than the TTL the whole
	// table is expired and the prune could otherwise eat the restore's
	// budget; the loads quarantine what it did not reach and the periodic
	// prune catches up.
	pruneCtx, cancelPrune := context.WithTimeout(ctx, restorePruneBudget)
	if _, err := p.store.PruneCacheRoutingState(pruneCtx, now, ttl, now.Add(-ttl)); err != nil {
		p.logger.Warn("cache routing persistence: boot prune did not finish; the periodic prune catches up", "error", err)
	}
	cancelPrune()
	demand, err := p.store.LoadCacheDemand(ctx, now.Add(-ttl), now, maxDemand)
	if err != nil {
		return nil, err
	}
	holders, err := p.store.LoadCacheHolders(ctx, now, ttl, maxHolders)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	// Rows parked while the restore was unavailable may have expired
	// meanwhile; drop them first so they never take the cap from rows
	// still valid.
	p.prunePendingLocked(now)
	// Rows this run already decided to delete (tombstones queued while the
	// store was unreachable; nothing has been written yet, so every one not
	// dropped at the dirty cap is still pending here) are older than that
	// decision: neither a parked copy nor the loaded copy may enter the
	// pending set, or the flush that drains the tombstone would let a later
	// reconnect bind it.
	if len(p.holderDeletes) > 0 {
		for pk, bucket := range p.pending {
			for hk := range bucket {
				if _, dead := p.holderDeletes[hk]; dead {
					p.removeParkedLocked(pk, hk)
					p.counters.droppedPending++
				}
			}
		}
	}
	// Merge into whatever is already parked: a provider that disconnected
	// before a retried restore parked this run's evidence here, and the
	// store may not hold it yet. The newer record wins per (key, epoch).
	restored := 0
	for _, rec := range holders {
		rec, ok := ClampToTTL(rec, now, ttl)
		if !ok {
			p.counters.droppedPending++
			continue
		}
		hk := rec.HolderKey()
		if _, dead := p.holderDeletes[hk]; dead {
			p.counters.droppedPending++
			continue
		}
		pk := pendingKey(rec.CacheEpoch, rec.ModelID)
		if parked, ok := p.pending[pk][hk]; ok {
			p.pending[pk][hk] = crs.Later(parked, rec)
			restored++
			continue
		}
		if p.pendingCount >= p.maxPending {
			p.counters.droppedPending++
			continue
		}
		p.addParkedLocked(pk, rec)
		restored++
	}
	p.counters.restoredHolders = restored
	p.ready = true
	p.mu.Unlock()
	return demand, nil
}

// SeedDemandPersisted records the restored demand entries the registry's
// index accepted as already persisted, so the next observation of each key
// is not written again inside the granularity. Entries the index rejected
// (outside its window, or evicted) are not seeded: a later observation of
// such a key must reach the store.
func (p *Persister) SeedDemandPersisted(accepted []crs.DemandRecord) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, rec := range accepted {
		p.demandPersisted[rec.Key] = rec.SeenAt
	}
	p.counters.restoredDemand = len(accepted)
}

// ClampToTTL applies the current routing TTL to a restored or parked row: the
// row expires no later than UpdatedAt + ttl, and a row already past that is
// reported as not restorable. The store merge keeps the greatest expiry, so
// without this a row written under a longer TTL would route past today's.
func ClampToTTL(rec crs.HolderRecord, now time.Time, ttl time.Duration) (crs.HolderRecord, bool) {
	if ttl > 0 {
		if limit := rec.UpdatedAt.Add(ttl); limit.Before(rec.ExpiresAt) {
			rec.ExpiresAt = limit
		}
	}
	if !rec.ExpiresAt.After(now) {
		return rec, false
	}
	return rec, true
}
