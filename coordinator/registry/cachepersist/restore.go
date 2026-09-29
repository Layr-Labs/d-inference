package cachepersist

import (
	"context"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Restore loads the durable copy. If the store's rows were written under a
// different cache-key generation (the master key changed), both tables are
// reset first: their HMAC-derived keys can never match a request. Demand
// entries within ttl are returned, newest first up to maxDemand, for the
// registry to seed its index directly. Holder rows are clamped to the current
// ttl (a row written under a longer TTL must not outlive today's setting),
// loaded longest-lived first up to maxHolders, and parked until the registry
// binds them to a provider whose capabilities match.
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
		p.mu.Lock()
		p.counters.keyRotated = stored != ""
		p.mu.Unlock()
		return nil, nil
	}
	demand, err := p.store.LoadCacheDemand(ctx, now.Add(-ttl), maxDemand)
	if err != nil {
		return nil, err
	}
	holders, err := p.store.LoadCacheHolders(ctx, now, maxHolders)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	p.pending = make(map[string][]crs.HolderRecord)
	p.pendingCount = 0
	for _, rec := range holders {
		rec, ok := ClampToTTL(rec, now, ttl)
		if !ok {
			p.counters.droppedPending++
			continue
		}
		if p.pendingCount >= p.maxPending {
			p.counters.droppedPending++
			continue
		}
		pk := pendingKey(rec.CacheEpoch, rec.ModelID)
		p.pending[pk] = append(p.pending[pk], rec)
		p.pendingCount++
	}
	p.counters.restoredHolders = p.pendingCount
	p.counters.restoredDemand = len(demand)
	for _, rec := range demand {
		p.demandPersisted[rec.Key] = rec.SeenAt
	}
	p.mu.Unlock()
	return demand, nil
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
