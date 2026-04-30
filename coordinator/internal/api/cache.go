package api

import (
	"net/http"
	"sync"
	"time"
)

// ttlCache stores pre-serialized JSON bytes keyed by request signature.
// Skipping both the DB query and json.Marshal on hit makes hot endpoints
// (stats, leaderboard, model catalog) sub-millisecond.
//
// Single-node in-memory only — sized for tens of keys, not millions. Hits
// are just a map lookup under RLock; misses recompute and Set without
// locking the read path.
type ttlCache struct {
	mu   sync.RWMutex
	data map[string]ttlEntry
}

type ttlEntry struct {
	value     []byte
	expiresAt time.Time
}

func newTTLCache() *ttlCache {
	return &ttlCache{data: make(map[string]ttlEntry)}
}

// Get returns the cached bytes if present and not expired.
func (c *ttlCache) Get(key string) ([]byte, bool) {
	c.mu.RLock()
	e, ok := c.data[key]
	c.mu.RUnlock()
	if !ok || time.Now().After(e.expiresAt) {
		return nil, false
	}
	return e.value, true
}

// Set stores bytes with an absolute expiry time.
func (c *ttlCache) Set(key string, value []byte, ttl time.Duration) {
	c.mu.Lock()
	c.data[key] = ttlEntry{value: value, expiresAt: time.Now().Add(ttl)}
	c.mu.Unlock()
}

// Invalidate removes a single key. Useful when an action changes the
// underlying data (e.g. registering a new release invalidates cached
// /api/version and /v1/runtime/manifest).
func (c *ttlCache) Invalidate(key string) {
	c.mu.Lock()
	delete(c.data, key)
	c.mu.Unlock()
}

// Purge expired entries. Called by a background goroutine — bounded
// growth even when keys are added but never re-read.
func (c *ttlCache) PurgeExpired() {
	now := time.Now()
	c.mu.Lock()
	for k, e := range c.data {
		if now.After(e.expiresAt) {
			delete(c.data, k)
		}
	}
	c.mu.Unlock()
}

// writeCachedJSON writes pre-serialized JSON bytes with the standard
// Content-Type header. Used on cache hit to skip json.Marshal.
func writeCachedJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
