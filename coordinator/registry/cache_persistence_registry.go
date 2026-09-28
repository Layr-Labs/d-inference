package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registry-side wiring for cache routing state persistence: start (restore +
// loops), bind on capability apply, final flush, and status.

// cacheRoutingStateStore returns the store's persistence surface, if any.
func (r *Registry) cacheRoutingStateStore() (store.CacheRoutingStateStore, bool) {
	if r == nil || r.store == nil {
		return nil, false
	}
	return store.As[store.CacheRoutingStateStore](r.store)
}

// StartCacheRoutingPersistence restores the durable copy into the current
// tracker and starts the flush and prune loops. It is a no-op when cache
// routing is off, when the store cannot persist, or when persistence is
// disabled by configuration. Call it after ConfigureCacheRouting and SetStore.
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
	r.mu.RUnlock()
	if tracker == nil || mode == CacheRoutingOff {
		return CacheRoutingPersistenceStatus{}, nil
	}
	persister := newCacheRoutingPersister(st, r.logger)
	now := tracker.now()
	if err := persister.restore(ctx, tracker, now); err != nil {
		return CacheRoutingPersistenceStatus{}, err
	}
	tracker.mu.Lock()
	tracker.persister = persister
	tracker.mu.Unlock()
	tracker.demand.setOnTouched(persister.markDemand)
	r.mu.Lock()
	r.cachePersister = persister
	r.mu.Unlock()
	// Providers that registered before the restore (none at boot, but tests
	// and reconfigures may) bind now.
	r.bindRestoredHoldersForConnectedProviders(now)
	go r.runCacheRoutingPersistence(ctx, persister)
	return persister.status(), nil
}

func (r *Registry) bindRestoredHoldersForConnectedProviders(now time.Time) {
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
		p.mu.Lock()
		caps := clonePrefixCacheCapabilities(p.PrefixCacheV2Models)
		tracker.mu.Lock()
		tracker.bindPendingLocked(p, caps, now)
		tracker.mu.Unlock()
		p.mu.Unlock()
	}
}

func (r *Registry) runCacheRoutingPersistence(ctx context.Context, p *cacheRoutingPersister) {
	flush := time.NewTicker(cacheRoutingFlushInterval)
	prune := time.NewTicker(cacheRoutingPruneInterval)
	defer flush.Stop()
	defer prune.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-flush.C:
			flushCtx, cancel := context.WithTimeout(context.Background(), cacheRoutingFlushInterval*2)
			_ = p.flush(flushCtx)
			cancel()
		case <-prune.C:
			r.mu.RLock()
			tracker := r.cacheRouting
			r.mu.RUnlock()
			if tracker == nil {
				continue
			}
			pruneCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
			p.prune(pruneCtx, tracker.now(), tracker.ttl)
			cancel()
		}
	}
}

// FlushCacheRoutingState writes everything marked dirty. Called once on
// shutdown after the drain, and by tests.
func (r *Registry) FlushCacheRoutingState(ctx context.Context) error {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	p := r.cachePersister
	r.mu.RUnlock()
	return p.flush(ctx)
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
	return p.status()
}
