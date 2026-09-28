package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// cacheRoutingRestoreTimeout bounds the boot-time load of the durable copy.
const cacheRoutingRestoreTimeout = 30 * time.Second

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
	existing := r.cachePersister
	r.mu.RUnlock()
	if existing != nil {
		return existing.status(), nil
	}
	if tracker == nil || mode == CacheRoutingOff {
		return CacheRoutingPersistenceStatus{}, nil
	}
	persister := newCacheRoutingPersister(st, r.logger)
	now := tracker.now()
	// The restore is bounded so a slow store cannot hold the process before it
	// listens; a failed restore still leaves write-behind on, so the next boot
	// has something to restore.
	restoreCtx, cancel := context.WithTimeout(ctx, cacheRoutingRestoreTimeout)
	restoreErr := persister.restore(restoreCtx, tracker, now)
	cancel()
	tracker.mu.Lock()
	tracker.persister = persister
	tracker.mu.Unlock()
	tracker.demand.setOnTouched(persister.markDemand)
	r.mu.Lock()
	r.cachePersister = persister
	r.mu.Unlock()
	// Providers that registered before the restore (none at boot, but tests
	// and reconfigures may) bind now.
	r.bindRestoredHoldersForConnectedProviders()
	go r.runCacheRoutingPersistence(ctx, persister)
	return persister.status(), restoreErr
}

// bindRestoredHolders binds parked rows for one provider's capabilities in
// the provider.mu → tracker.mu order the receipt path uses. It is called from
// UpdatePrefixCacheSnapshot (provider.mu already held) and from Register.
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
	if p == nil || !p.hasPending() {
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
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker == nil {
		return
	}
	p.mu.Lock()
	caps := clonePrefixCacheCapabilities(p.PrefixCacheV2Models)
	p.mu.Unlock()
	tracker.bindRestoredHolders(p, caps)
}

func (r *Registry) bindRestoredHoldersForConnectedProviders() {
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
		p.mu.Unlock()
		tracker.bindRestoredHolders(p, caps)
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

// FlushCacheRoutingState writes everything marked dirty, in as many bounded
// flushes as it takes. Called once on shutdown after the drain, and by tests.
func (r *Registry) FlushCacheRoutingState(ctx context.Context) error {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	p := r.cachePersister
	r.mu.RUnlock()
	return p.flushAll(ctx)
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
