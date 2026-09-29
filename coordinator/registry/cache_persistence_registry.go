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
	done := make(chan struct{})
	r.mu.Lock()
	r.cachePersister = persister
	r.cachePersistDone = done
	r.mu.Unlock()
	restoreErr := r.restoreCacheRoutingState(ctx, persister, tracker)
	go func() {
		defer close(done)
		r.runCacheRoutingPersistence(ctx, persister)
	}()
	return persister.Status(), restoreErr
}

// WaitCacheRoutingPersistence waits until the persistence loop started by
// StartCacheRoutingPersistence has exited (its context cancelled) or ctx
// expires. Shutdown joins the loop before the final flush, so a restore
// retry in flight has either made the persister ready or been cancelled by
// the time readiness is checked, and no flush of the loop's own can run
// behind the final one. True when the loop has exited (or never ran).
func (r *Registry) WaitCacheRoutingPersistence(ctx context.Context) bool {
	if r == nil {
		return true
	}
	r.mu.RLock()
	done := r.cachePersistDone
	r.mu.RUnlock()
	if done == nil {
		return true
	}
	select {
	case <-done:
		return true
	case <-ctx.Done():
		return false
	}
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
// UpdatePrefixCacheSnapshot (provider.mu held for that first chunk), from
// bindChunksWhileOwned at registration, on the heartbeat path and for every
// connected provider after a (retried) restore.
func (t *cacheRoutingTracker) bindRestoredHolders(provider *Provider, capabilities map[string]protocol.PrefixCacheV2Capability) (remaining bool) {
	if t == nil || len(capabilities) == 0 {
		return false
	}
	// Heartbeats carry capabilities every few seconds; in the steady state
	// nothing is parked, so check the leaf lock first and take tracker.mu
	// only when there is something to bind.
	t.mu.Lock()
	p := t.persister
	t.mu.Unlock()
	if !p.HasPending() {
		return false
	}
	// One chunk per call: the callers that own a large bucket (registration,
	// a retried restore) loop, re-taking the registry read lock and
	// re-checking session ownership around each chunk, so neither the
	// tracker lock nor the registry lock is held across a whole rebuild.
	t.mu.Lock()
	remaining = t.bindPendingLocked(provider, capabilities, t.now())
	t.mu.Unlock()
	return remaining
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
	r.bindChunksWhileOwned(p)
}

// bindChunksWhileOwned binds a provider's parked rows chunk by chunk, taking
// the registry read lock and re-checking that the registry still owns the
// session around each chunk, so neither a queued writer (Register,
// disconnectProvider) nor a request on the tracker lock waits behind a
// whole rebuild.
func (r *Registry) bindChunksWhileOwned(p *Provider) {
	for {
		r.mu.RLock()
		tracker := r.cacheRouting
		owned := tracker != nil && r.providers[p.ID] == p
		var remaining bool
		if owned {
			// provider.mu is held through the chunk, the order the receipt
			// and capability-apply paths use: a heartbeat cannot publish a
			// new capability and invalidate the old holders between this
			// snapshot of the capabilities and the bind that uses it.
			p.mu.Lock()
			caps := clonePrefixCacheCapabilities(p.PrefixCacheV2Models)
			remaining = tracker.bindRestoredHolders(p, caps)
			p.mu.Unlock()
		}
		r.mu.RUnlock()
		if !owned || !remaining {
			return
		}
	}
}

// dropParkedWhileStale settles the rows parked under d in chunks, re-taking
// the registry read lock and the session's provider lock around each chunk
// (the capability-apply order) and re-checking under them that the session
// still owns its ID and that its current SSD capability for the model still
// leaves the epoch behind. Two heartbeats applied back to back can move a
// model from epoch A to B and back to A: the first apply records the drop
// of A's bucket, the second republishes A and binds a chunk of it, and a
// drop running after both would otherwise consume, and durably delete, the
// rows the second apply made bindable again. A session that lost its ID
// leaves the rows parked, for the next session with that epoch or the TTL
// prune.
func (r *Registry) dropParkedWhileStale(p *Provider, d parkedDrop) {
	if p == nil {
		return
	}
	for {
		r.mu.RLock()
		tracker := r.cacheRouting
		owned := tracker != nil && r.providers[p.ID] == p
		stale, more := false, false
		if owned {
			p.mu.Lock()
			current, has := p.PrefixCacheV2Models[d.model]
			stale = !has || current.CacheEpoch != d.epoch
			if stale {
				more = tracker.settleParkedChunk(d.epoch, d.model)
			}
			p.mu.Unlock()
		}
		r.mu.RUnlock()
		if !owned || !stale || !more {
			return
		}
	}
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
		r.bindChunksWhileOwned(p)
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
			// Derived from the loop's context: a prune of expired rows is
			// safe to abort, and one in flight must not outlive the
			// shutdown join.
			pruneCtx, cancel := context.WithTimeout(ctx, time.Minute)
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
