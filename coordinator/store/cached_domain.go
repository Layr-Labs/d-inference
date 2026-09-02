package store

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

// domainCache is the bounded TTL map behind one cached domain of CachedStore
// (users, model-registry records). It is deliberately minimal: one mutex, one
// map, a generation counter that orders reads against invalidations, and
// random eviction at capacity.
//
// Entries are immutable once stored -- readers get clones, invalidation drops
// entries rather than editing them -- so a value pointer taken under the lock
// may be read after the lock is released.
type domainCache[V any] struct {
	ttl         time.Duration // positive-entry lifetime
	negativeTTL time.Duration // "not found" entry lifetime
	maxEntries  int           // hard cap; <= 0 means unbounded
	now         func() time.Time

	mu      sync.Mutex
	entries map[string]cacheEntry[V]
	// gen is bumped by every invalidation. A read-through snapshots gen
	// before calling the inner store and only publishes its result if gen is
	// unchanged afterwards, so a value loaded concurrently with (and possibly
	// older than) a write can never outlive that write's invalidation.
	gen uint64

	hits          atomic.Uint64
	misses        atomic.Uint64
	negativeHits  atomic.Uint64
	evictions     atomic.Uint64
	invalidations atomic.Uint64
}

type cacheEntry[V any] struct {
	value     *V    // nil for a negative entry
	err       error // non-nil for a negative entry
	expiresAt time.Time
}

func newDomainCache[V any](ttl, negativeTTL time.Duration, maxEntries int, now func() time.Time) *domainCache[V] {
	if now == nil {
		now = time.Now
	}
	return &domainCache[V]{
		ttl:         ttl,
		negativeTTL: negativeTTL,
		maxEntries:  maxEntries,
		now:         now,
		entries:     make(map[string]cacheEntry[V]),
	}
}

// get is the read-through: serve from cache, else load from the inner store
// and remember the result. Positive results are cached for ttl, ErrNotFound
// results for negativeTTL, and any other error (timeouts, connection
// failures) is passed through uncached so a DB blip is never pinned as a
// miss. clone must return an independent copy; it is applied to every
// positive result handed to the caller so the canonical cached value can
// never be mutated through a returned pointer.
func (c *domainCache[V]) get(key string, load func() (*V, error), clone func(*V) *V) (*V, error) {
	if e, ok := c.lookup(key); ok {
		if e.err != nil {
			c.negativeHits.Add(1)
			return nil, e.err
		}
		c.hits.Add(1)
		return clone(e.value), nil
	}
	c.misses.Add(1)

	gen := c.generation()
	v, err := load()
	switch {
	case err == nil:
		c.store(key, gen, v, nil)
		return clone(v), nil
	case errors.Is(err, ErrNotFound):
		c.store(key, gen, nil, err)
		return nil, err
	default:
		return nil, err
	}
}

// lookup returns the live entry for key. Expired entries are dropped on the
// way out so the map only ever holds entries that were valid at last touch.
func (c *domainCache[V]) lookup(key string) (cacheEntry[V], bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok {
		return cacheEntry[V]{}, false
	}
	if !c.now().Before(e.expiresAt) {
		delete(c.entries, key)
		return cacheEntry[V]{}, false
	}
	return e, true
}

func (c *domainCache[V]) generation() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.gen
}

// store publishes a loaded result unless an invalidation happened after gen
// was snapshotted (see the gen field). At capacity it first sweeps expired
// entries and, if that frees nothing, drops one arbitrary entry -- Go's
// randomized map iteration gives a cheap random-replacement policy.
func (c *domainCache[V]) store(key string, gen uint64, value *V, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.gen != gen {
		return
	}
	ttl := c.ttl
	if err != nil {
		ttl = c.negativeTTL
	}
	if ttl <= 0 {
		return
	}
	if _, present := c.entries[key]; !present && c.maxEntries > 0 && len(c.entries) >= c.maxEntries {
		c.evictLocked()
	}
	c.entries[key] = cacheEntry[V]{value: value, err: err, expiresAt: c.now().Add(ttl)}
}

func (c *domainCache[V]) evictLocked() {
	now := c.now()
	removed := 0
	victim := ""
	for k, e := range c.entries {
		if victim == "" {
			victim = k
		}
		if !now.Before(e.expiresAt) {
			delete(c.entries, k)
			removed++
		}
	}
	if removed == 0 && victim != "" {
		delete(c.entries, victim)
		removed = 1
	}
	c.evictions.Add(uint64(removed))
}

// invalidate drops every entry and bumps the generation so in-flight loads
// that started before the corresponding write cannot repopulate the domain
// with pre-write data.
func (c *domainCache[V]) invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.gen++
	clear(c.entries)
	c.invalidations.Add(1)
}

func (c *domainCache[V]) size() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.entries)
}

func (c *domainCache[V]) counters() CacheCounters {
	return CacheCounters{
		Hits:          c.hits.Load(),
		Misses:        c.misses.Load(),
		NegativeHits:  c.negativeHits.Load(),
		Evictions:     c.evictions.Load(),
		Invalidations: c.invalidations.Load(),
		Entries:       c.size(),
	}
}
