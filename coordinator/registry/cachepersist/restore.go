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
	demand, err := p.store.LoadCacheDemand(ctx, now.Add(-ttl), now, maxDemand)
	if err != nil {
		return nil, err
	}
	holders, err := p.store.LoadCacheHolders(ctx, now, ttl, maxHolders)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
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
		pk := pendingKey(rec.CacheEpoch, rec.ModelID)
		if i := indexOfParked(p.pending[pk], rec.HolderKey()); i >= 0 {
			p.pending[pk][i] = crs.Later(p.pending[pk][i], rec)
			restored++
			continue
		}
		if p.pendingCount >= p.maxPending {
			p.counters.droppedPending++
			continue
		}
		p.pending[pk] = append(p.pending[pk], rec)
		p.pendingCount++
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
