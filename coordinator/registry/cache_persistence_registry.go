package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Registry wiring for cache routing state persistence: start (restore +
// loops), bind on registration and capability apply, final flush, status.

// cacheRoutingRestoreTimeout bounds the boot-time load of the durable copy.
const cacheRoutingRestoreTimeout = 30 * time.Second

// CacheRoutingPersistenceStatus is the persister's status as exposed on the
// cache status lifecycle block.
type CacheRoutingPersistenceStatus = cachepersist.Status

// cacheRoutingStateStore returns the store's persistence surface, if any.
func (r *Registry) cacheRoutingStateStore() (crs.Store, bool) {
	if r == nil || r.store == nil {
		return nil, false
	}
	return store.As[crs.Store](r.store)
}

// StartCacheRoutingPersistence restores the durable copy into the current
// tracker and starts the flush and prune loops. It is a no-op when cache
// routing is off, when the store cannot persist, or when it already started.
// Call it after ConfigureCacheRouting and SetStore. A failed restore is
// reported; the flush loop retries it every tick and writes nothing until it
// succeeds, since rows written before the key generation is recorded would
// be reset as foreign by the next boot.
func (r *Registry) StartCacheRoutingPersistence(ctx context.Context) (CacheRoutingPersistenceStatus, error) {
	if r == nil {
		return CacheRoutingPersistenceStatus{}, nil
	}
	st, ok := r.cacheRoutingStateStore()
	if !ok {
		return CacheRoutingPersistenceStatus{}, nil
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	mode := r.cacheRoutingMode
	existing := r.cachePersister
	r.mu.RUnlock()
	if existing != nil {
		return existing.Status(), nil
	}
	if tracker == nil || mode == CacheRoutingOff {
		return CacheRoutingPersistenceStatus{}, nil
	}
	r.mu.RLock()
	fingerprint := r.cacheRouteKeys.persistFingerprint
	r.mu.RUnlock()
	persister := cachepersist.New(st, r.logger, cachepersist.Options{
		MaxPending: tracker.maxEntries, DemandTTL: tracker.ttl, Fingerprint: fingerprint,
	})
	tracker.mu.Lock()
	tracker.persister = persister
	tracker.mu.Unlock()
	tracker.demand.setOnTouched(persister.MarkDemand)
	r.mu.Lock()
	r.cachePersister = persister
	r.mu.Unlock()
	restoreErr := r.restoreCacheRoutingState(ctx, persister, tracker)
	go r.runCacheRoutingPersistence(ctx, persister)
	return persister.Status(), restoreErr
}

// restoreCacheRoutingState loads the durable copy into the tracker: the key
// generation is established (or the tables reset), demand entries seed the
// index and are reported back as persisted, holders park, and providers that
// are already connected (none at boot; tests, reconfigures and a retried
// restore) bind their parked rows.
func (r *Registry) restoreCacheRoutingState(ctx context.Context, persister *cachepersist.Persister, tracker *cacheRoutingTracker) error {
	now := tracker.now()
	restoreCtx, cancel := context.WithTimeout(ctx, cacheRoutingRestoreTimeout)
	demand, err := persister.Restore(restoreCtx, now, tracker.ttl, tracker.maxEntries, tracker.demand.limit)
	cancel()
	if err != nil {
		return err
	}
	persister.SeedDemandPersisted(tracker.demand.restore(demand, now))
	r.bindRestoredHoldersForConnectedProviders()
	return nil
}

// bindRestoredHolders binds parked rows for one provider's capabilities in
// the provider.mu → tracker.mu order the receipt path uses. It is called from
// UpdatePrefixCacheSnapshot (provider.mu already held), from Register, and
// for every connected provider after a (retried) restore.
func (t *cacheRoutingTracker) bindRestoredHolders(provider *Provider, capabilities map[string]protocol.PrefixCacheV2Capability) {
	if t == nil || len(capabilities) == 0 {
		return
	}
	// Heartbeats carry capabilities every few seconds; in the steady state
	// nothing is parked, so check the leaf lock first and take tracker.mu
	// only when there is something to bind.
	t.mu.Lock()
	p := t.persister
	t.mu.Unlock()
	if !p.HasPending() {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.bindPendingLocked(provider, capabilities, t.now())
}

// bindRegisteredProvider runs at the end of Register: registration carries
// the provider's capabilities, so its parked rows bind before the first
// heartbeat.
func (r *Registry) bindRegisteredProvider(p *Provider) {
	if r == nil || p == nil {
		return
	}
	// Under the read lock, and only while the registry still owns this
	// session: a disconnect that won the race (the deliberate reconnect
	// eviction included) removes the provider under r.mu and cleans the
	// tracker up afterwards, so rows bound here can never land on a
	// session whose cleanup already ran.
	r.mu.RLock()
	defer r.mu.RUnlock()
	tracker := r.cacheRouting
	if tracker == nil || r.providers[p.ID] != p {
		return
	}
	p.mu.Lock()
	caps := clonePrefixCacheCapabilities(p.PrefixCacheV2Models)
	p.mu.Unlock()
	tracker.bindRestoredHolders(p, caps)
}

func (r *Registry) bindRestoredHoldersForConnectedProviders() {
	// Held across each bind: disconnectProvider removes a provider under
	// r.mu and runs the tracker cleanup that parks its holders afterwards,
	// so a provider seen here is either still connected when its rows bind
	// or is removed, and cleaned up, only after they bound. Binding a
	// provider a concurrent disconnect had already cleaned up would strand
	// the rows on a dead provider ID. The order r.mu → provider.mu →
	// tracker.mu is the capability-apply order.
	r.mu.RLock()
	tracker := r.cacheRouting
	providers := make([]*Provider, 0, len(r.providers))
	for _, p := range r.providers {
		providers = append(providers, p)
	}
	r.mu.RUnlock()
	if tracker == nil {
		return
	}
	for _, p := range providers {
		// Per provider, so a queued writer never waits behind the whole
		// pass: the membership check and the bind share one read hold.
		r.mu.RLock()
		if r.providers[p.ID] == p {
			p.mu.Lock()
			caps := clonePrefixCacheCapabilities(p.PrefixCacheV2Models)
			p.mu.Unlock()
			tracker.bindRestoredHolders(p, caps)
		}
		r.mu.RUnlock()
	}
}

func (r *Registry) runCacheRoutingPersistence(ctx context.Context, p *cachepersist.Persister) {
	flush := time.NewTicker(cachepersist.FlushInterval)
	prune := time.NewTicker(cachepersist.PruneInterval)
	defer flush.Stop()
	defer prune.Stop()
	attempts := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-flush.C:
			if !p.Ready() {
				// The boot restore failed before the key generation was
				// established; retry it here, and write nothing until it
				// succeeds.
				r.mu.RLock()
				tracker := r.cacheRouting
				r.mu.RUnlock()
				if tracker == nil {
					continue
				}
				attempts++
				if err := r.restoreCacheRoutingState(ctx, p, tracker); err != nil {
					if attempts == 1 || attempts%12 == 0 {
						r.logger.Warn("cache routing persistence restore retry failed; nothing is written until it succeeds",
							"error", err, "attempts", attempts)
					}
					continue
				}
				s := p.Status()
				r.logger.Info("cache routing persistence restored after retry", "attempts", attempts,
					"holders_pending", s.PendingHolders, "demand_entries", s.RestoredDemand, "key_rotated", s.KeyRotated)
			}
			flushCtx, cancel := context.WithTimeout(context.Background(), cachepersist.FlushInterval*2)
			_ = p.Flush(flushCtx)
			cancel()
		case <-prune.C:
			r.mu.RLock()
			tracker := r.cacheRouting
			r.mu.RUnlock()
			if tracker == nil {
				continue
			}
			pruneCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
			p.Prune(pruneCtx, tracker.now(), tracker.ttl)
			cancel()
		}
	}
}

// FlushCacheRoutingState writes everything marked dirty, in as many bounded
// flushes as it takes. Flushes are serialized with the periodic loop, so a
// shutdown flush never races a tick that is still writing. Called once on
// shutdown after the HTTP server and the provider sockets are down, and by
// tests.
func (r *Registry) FlushCacheRoutingState(ctx context.Context) error {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	p := r.cachePersister
	r.mu.RUnlock()
	return p.FlushAll(ctx)
}

// CacheRoutingPersistenceStatus reports the persister's counters; Enabled is
// false when persistence never started.
func (r *Registry) CacheRoutingPersistenceStatus() CacheRoutingPersistenceStatus {
	if r == nil {
		return CacheRoutingPersistenceStatus{}
	}
	r.mu.RLock()
	p := r.cachePersister
	r.mu.RUnlock()
	return p.Status()
}
