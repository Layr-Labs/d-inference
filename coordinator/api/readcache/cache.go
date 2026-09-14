package readcache

import (
	"sync"
	"time"
)

// Cache stores pre-serialized JSON bytes — or, for shared intermediate
// results such as the public model entry list, a typed value — keyed by
// request signature. Skipping both the DB query and json.Marshal on hit makes
// hot endpoints (stats, leaderboard, model catalog) sub-millisecond.
//
// Single-node in-memory only — sized for tens of keys, not millions. Hits
// are just a map lookup under RLock; misses recompute and Set without
// locking the read path.
type Cache struct {
	mu   sync.RWMutex
	data map[string]entry
	// generation orders guarded fills against invalidation.
	generation uint64
}

type entry struct {
	value     []byte
	obj       any
	expiresAt time.Time
}

func New() *Cache {
	return &Cache{data: make(map[string]entry)}
}

func (c *Cache) lookup(key string) (entry, bool) {
	c.mu.RLock()
	e, ok := c.data[key]
	c.mu.RUnlock()
	if !ok || time.Now().After(e.expiresAt) {
		return entry{}, false
	}
	return e, true
}

// Get returns the cached bytes if present and not expired.
func (c *Cache) Get(key string) ([]byte, bool) {
	e, ok := c.lookup(key)
	if !ok || e.value == nil {
		return nil, false
	}
	return e.value, true
}

// GetValue returns the cached typed value if present and not expired. The
// value is shared between all callers and must be treated as immutable.
func (c *Cache) GetValue(key string) (any, bool) {
	e, ok := c.lookup(key)
	if !ok || e.obj == nil {
		return nil, false
	}
	return e.obj, true
}

// Set stores bytes with an absolute expiry time.
func (c *Cache) Set(key string, value []byte, ttl time.Duration) {
	c.mu.Lock()
	c.data[key] = entry{value: value, expiresAt: time.Now().Add(ttl)}
	c.mu.Unlock()
}

// SetValue stores a typed value with an absolute expiry time.
func (c *Cache) SetValue(key string, v any, ttl time.Duration) {
	c.mu.Lock()
	c.data[key] = entry{obj: v, expiresAt: time.Now().Add(ttl)}
	c.mu.Unlock()
}

// Invalidate removes a single key. Useful when an action changes the
// underlying data (e.g. registering a new release invalidates cached
// /api/version and /v1/runtime/manifest).
func (c *Cache) Invalidate(key string) {
	c.mu.Lock()
	delete(c.data, key)
	c.generation++
	c.mu.Unlock()
}

// Purge expired entries. Called by a background goroutine — bounded
// growth even when keys are added but never re-read.
func (c *Cache) PurgeExpired() {
	now := time.Now()
	c.mu.Lock()
	for k, e := range c.data {
		if now.After(e.expiresAt) {
			delete(c.data, k)
		}
	}
	c.mu.Unlock()
}

// Len returns the number of entries currently held (including not-yet-purged
// expired ones). Used by the janitor's tests to observe reclamation.
func (c *Cache) Len() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.data)
}
