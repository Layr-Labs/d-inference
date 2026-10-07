package readcache

import "time"

// Generation snapshots the invalidation generation before a catalog
// computation reads its inputs. A concurrent admin sync may invalidate the
// result while it is being built; that request can finish with its snapshot,
// but must not repopulate the cache for requests after the sync completes.
func (c *Cache) Generation() uint64 {
	if c == nil {
		return 0
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.generation
}

// SetIfCurrent publishes bytes only if no invalidation raced their computation.
func (c *Cache) SetIfCurrent(key string, body []byte, ttl time.Duration, generation uint64) {
	c.setEntryIfCurrent(key, ttlEntry{value: body}, ttl, generation)
}

// SetValueIfCurrent is SetIfCurrent for immutable typed values.
func (c *Cache) SetValueIfCurrent(key string, value any, ttl time.Duration, generation uint64) {
	c.setEntryIfCurrent(key, ttlEntry{obj: value}, ttl, generation)
}

// setEntryIfCurrent publishes a catalog fill only if no invalidation
// has raced it. The comparison and write use the same lock as Invalidate, so
// a successful check cannot race with the eviction it is meant to preserve.
func (c *Cache) setEntryIfCurrent(key string, entry ttlEntry, ttl time.Duration, generation uint64) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generation != generation {
		return
	}
	entry.expiresAt = time.Now().Add(ttl)
	c.data[key] = entry
}
