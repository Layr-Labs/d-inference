package requestauth

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// keyEntry stores the authenticated key record for a single raw API
// key. Cached to skip DB round trips on repeat requests with the same key. A
// nil key means the token is known-invalid (negative cache).
type keyEntry struct {
	key      *store.APIKey
	cachedAt time.Time
	gen      uint64 // cache generation this entry was stored under
}

const (
	keyCacheTTL     = 60 * time.Second
	keyCacheMaxSize = 1000
)

// keyCache owns authenticated key results and all cache invalidation state.
type keyCache struct {
	mu         sync.RWMutex
	entries    map[string]keyEntry
	generation uint64
}

// lookup returns a cached AuthenticateKey result if present and
// not expired. Returns false on miss or expiry.
func (c *keyCache) lookup(token string) (keyEntry, bool) {
	c.mu.RLock()
	entry, ok := c.entries[token]
	gen := c.generation
	c.mu.RUnlock()
	// Miss on absence, TTL expiry, or a stale generation (a key mutation has
	// occurred since the entry was cached).
	if !ok || entry.gen != gen || time.Since(entry.cachedAt) > keyCacheTTL {
		return keyEntry{}, false
	}
	return entry, true
}

// store inserts an auth result into the cache, stamped with the
// current generation. If the cache is at capacity, the oldest entry is evicted.
func (c *keyCache) store(token string, entry keyEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry.gen = c.generation
	if len(c.entries) >= keyCacheMaxSize {
		var oldest string
		var oldestTime time.Time
		for k, v := range c.entries {
			if oldest == "" || v.cachedAt.Before(oldestTime) {
				oldest = k
				oldestTime = v.cachedAt
			}
		}
		delete(c.entries, oldest)
	}
	c.entries[token] = entry
}

// invalidate removes a single key from the API key cache. Called
// when a key is revoked so stale positive results don't grant access.
func (c *keyCache) invalidate(token string) {
	c.mu.Lock()
	delete(c.entries, token)
	c.mu.Unlock()
}

// invalidateAll atomically invalidates every cached auth result by
// bumping the cache generation (entries cached under an older generation are
// ignored). Called BEFORE and AFTER a by-ID key mutation (update/revoke/rotate)
// where we don't hold the raw token: the pre-bump drops any pre-existing entry,
// and the post-bump drops any entry a concurrent request re-cached from
// pre-commit state during the mutation — closing the read-stale race.
func (c *keyCache) invalidateAll() {
	c.mu.Lock()
	c.generation++
	c.entries = make(map[string]keyEntry)
	c.mu.Unlock()
}
