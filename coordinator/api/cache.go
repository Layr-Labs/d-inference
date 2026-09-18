package api

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

// ttlCache stores pre-serialized JSON bytes — or, for shared intermediate
// results such as the public model entry list, a typed value — keyed by
// request signature. Skipping both the DB query and json.Marshal on hit makes
// hot endpoints (stats, leaderboard, model catalog) sub-millisecond.
//
// Single-node in-memory only — sized for tens of keys, not millions. Hits
// are just a map lookup under RLock; misses recompute and Set without
// locking the read path.
type ttlCache struct {
	mu   sync.RWMutex
	data map[string]ttlEntry
	// generation orders guarded fills against invalidation.
	generation uint64
}

type ttlEntry struct {
	value     []byte
	obj       any
	expiresAt time.Time
}

func newTTLCache() *ttlCache {
	return &ttlCache{data: make(map[string]ttlEntry)}
}

func (c *ttlCache) lookup(key string) (ttlEntry, bool) {
	c.mu.RLock()
	e, ok := c.data[key]
	c.mu.RUnlock()
	if !ok || time.Now().After(e.expiresAt) {
		return ttlEntry{}, false
	}
	return e, true
}

// Get returns the cached bytes if present and not expired.
func (c *ttlCache) Get(key string) ([]byte, bool) {
	e, ok := c.lookup(key)
	if !ok || e.value == nil {
		return nil, false
	}
	return e.value, true
}

// GetValue returns the cached typed value if present and not expired. The
// value is shared between all callers and must be treated as immutable.
func (c *ttlCache) GetValue(key string) (any, bool) {
	e, ok := c.lookup(key)
	if !ok || e.obj == nil {
		return nil, false
	}
	return e.obj, true
}

// Set stores bytes with an absolute expiry time.
func (c *ttlCache) Set(key string, value []byte, ttl time.Duration) {
	c.mu.Lock()
	c.data[key] = ttlEntry{value: value, expiresAt: time.Now().Add(ttl)}
	c.mu.Unlock()
}

// SetValue stores a typed value with an absolute expiry time.
func (c *ttlCache) SetValue(key string, v any, ttl time.Duration) {
	c.mu.Lock()
	c.data[key] = ttlEntry{obj: v, expiresAt: time.Now().Add(ttl)}
	c.mu.Unlock()
}

// Invalidate removes a single key. Useful when an action changes the
// underlying data (e.g. registering a new release invalidates cached
// /api/version and /v1/runtime/manifest).
func (c *ttlCache) Invalidate(key string) {
	c.mu.Lock()
	delete(c.data, key)
	c.generation++
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

// Len returns the number of entries currently held (including not-yet-purged
// expired ones). Used by the janitor's tests to observe reclamation.
func (c *ttlCache) Len() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.data)
}

// writeCachedJSON writes pre-serialized JSON bytes with the standard
// Content-Type header. Used on cache hit to skip json.Marshal.
func writeCachedJSON(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// encodeCachedJSON renders v exactly as writeJSON does (json.Encoder appends
// a trailing newline to the compact encoding), so a cache hit served by
// writeCachedJSON is byte-identical to the miss that populated it.
func encodeCachedJSON(v any) ([]byte, error) {
	body, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return append(body, '\n'), nil
}

// Nil-safe readCache accessors: handlers reached through a bare Server
// literal (some tests) have no cache and simply recompute every time.

func (s *Server) readCacheGet(key string) ([]byte, bool) {
	if s.readCache == nil {
		return nil, false
	}
	return s.readCache.Get(key)
}

func (s *Server) readCacheSet(key string, body []byte, ttl time.Duration) {
	if s.readCache != nil {
		s.readCache.Set(key, body, ttl)
	}
}

func (s *Server) readCacheGetValue(key string) (any, bool) {
	if s.readCache == nil {
		return nil, false
	}
	return s.readCache.GetValue(key)
}
