package cachepersist

import (
	"context"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// restorePruneBudget bounds the prune Restore runs before loading, inside the
// registry's restore timeout.
const restorePruneBudget = 10 * time.Second

// Restore loads the durable copy. If the store's rows were written under a
// different cache-key generation (a rotated master key, or a release that
// changed a key-derivation version), both tables are reset first: their
// HMAC-derived keys can never match a request. Demand
// entries within ttl (at most FutureSkew ahead of now, clamped to it) are
// returned, newest first up to maxDemand, for the registry to seed its index directly; the registry then
// reports the entries its index accepted with SeedDemandPersisted. Holder rows are loaded under the
// current ttl (the store clamps each row's expiry to UpdatedAt+ttl before it
// orders and caps, so a row written under a longer TTL neither outlives
// today's setting nor crowds a valid row out of the cap), longest-lived first
// up to maxHolders, and parked until the registry binds them to a provider
// whose capabilities match.
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
		switch stored {
		case "":
			p.logger.Info("cache routing persistence: recorded the cache-key generation; the durable copy starts empty")
		case crs.ResetInProgress:
			p.logger.Warn("cache routing persistence: a reset an earlier attempt did not finish was completed; the durable copy starts empty")
		default:
			p.logger.Warn("cache routing persistence: the cache-key generation changed (a rotated master key or a bumped derivation version); the durable copy was reset instead of restored")
		}
		p.queue.Mu.Lock()
		p.queue.Counters.KeyRotated = stored != "" && stored != crs.ResetInProgress
		p.queue.ResetPending = false // the reset covered any overflowed backlog
		p.queue.Ready = true
		p.queue.Mu.Unlock()
		return nil, nil
	}
	p.queue.Mu.Lock()
	overflowed := p.queue.ResetPending
	p.queue.Mu.Unlock()
	if overflowed {
		return nil, p.resetOverflowedRestore(ctx, "before the durable copy could be read")
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
	// Rows parked while the restore was unavailable may have expired
	// meanwhile; drop them first so they never take the cap from rows
	// still valid. In bounded lock holds, as is the merge below: a retried
	// restore runs while receipts are served, and a receipt holding the
	// tracker lock waits on p.queue.Mu.
	p.prunePendingChunked(now)
	// Flush gates on ready, so invalidations remain pending throughout the
	// load. Check each merge chunk against those fences and any overflow;
	// mark the restore ready only after the final chunk passes both checks.
	// Merge into whatever is already parked: a provider that disconnected
	// before a retried restore parked this run's evidence here, and the
	// store may not hold it yet. The newer record wins per (key, epoch).
	restored := 0
	for start := 0; start < len(holders); start += restoreMergeRows {
		end := min(start+restoreMergeRows, len(holders))
		p.queue.Mu.Lock()
		if p.queue.ResetPending {
			// The rows merged so far stay parked (checked against the
			// decisions then pending) and count as restored.
			p.queue.Counters.RestoredHolders = restored
			p.queue.Mu.Unlock()
			return nil, p.resetOverflowedRestore(ctx, "while the durable copy was being restored")
		}
		for _, rec := range holders[start:end] {
			rec, ok := ClampToTTL(rec, now, ttl)
			if !ok {
				p.queue.Counters.DroppedPending++
				continue
			}
			hk := rec.HolderKey()
			if p.tombstonedLocked(hk, rec.UpdatedAt) {
				p.queue.Counters.DroppedPending++
				continue
			}
			pk := pendingKey(rec.CacheEpoch, rec.ModelID)
			if parked, ok := p.queue.Pending[pk][hk]; ok {
				merged := crs.Later(parked, rec)
				p.queue.Pending[pk][hk] = merged
				if !merged.ExpiresAt.Equal(parked.ExpiresAt) {
					setTime(&p.queue.ParkedExpiry, hk, merged.ExpiresAt)
				}
				restored++
				continue
			}
			if p.queue.PendingCount >= p.queue.MaxPending {
				p.queue.Counters.DroppedPending++
				continue
			}
			p.addParkedLocked(pk, rec)
			restored++
		}
		p.queue.Mu.Unlock()
	}
	p.queue.Mu.Lock()
	if p.queue.ResetPending {
		// Released since the last chunk (or with nothing loaded): the rows
		// merged so far were checked against the decisions then pending
		// and count as restored, but the copy must not be read as
		// established.
		p.queue.Counters.RestoredHolders = restored
		p.queue.Mu.Unlock()
		return nil, p.resetOverflowedRestore(ctx, "while the durable copy was being restored")
	}
	p.queue.Counters.RestoredHolders = restored
	p.queue.Ready = true
	p.queue.Mu.Unlock()
	return demand, nil
}

// restoreMergeRows bounds the loaded rows one restore lock hold merges.
const restoreMergeRows = pruneBatchRows

// resetOverflowedRestore discards the durable copy instead of restoring it:
// the delete backlog outgrew its budget before, or while, the rows were read
// (MarkHolderDelete), and the decisions it released condemn rows the load
// would park. Live evidence rewrites the copy; the key generation counts as
// established, so flushes proceed.
func (p *Persister) resetOverflowedRestore(ctx context.Context, when string) error {
	if err := p.store.ResetCacheRoutingState(ctx, p.fingerprint); err != nil {
		return err
	}
	p.logger.Warn("cache routing persistence: the delete backlog outgrew its budget " + when + "; the durable copy was reset instead of restored")
	p.queue.Mu.Lock()
	p.queue.ResetPending = false
	p.queue.Ready = true
	p.queue.Mu.Unlock()
	return nil
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
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	for _, rec := range accepted {
		p.queue.DemandPersisted[rec.Key] = rec.SeenAt
	}
	p.queue.Counters.RestoredDemand = len(accepted)
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
