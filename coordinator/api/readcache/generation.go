package readcache

import "time"

// Generation snapshots invalidation before a caller reads the inputs for a
// cached result. A later invalidation prevents that fill from being published.
func (c *Cache) Generation() uint64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.generation
}

// SetIfCurrent publishes bytes only if no invalidation has raced their fill.
func (c *Cache) SetIfCurrent(key string, value []byte, ttl time.Duration, generation uint64) {
	c.setIfCurrent(key, entry{value: value}, ttl, generation)
}

// SetValueIfCurrent publishes an immutable value under the same generation
// fence as byte responses. The comparison and write share Invalidate's lock.
func (c *Cache) SetValueIfCurrent(key string, value any, ttl time.Duration, generation uint64) {
	c.setIfCurrent(key, entry{obj: value}, ttl, generation)
}

func (c *Cache) setIfCurrent(key string, value entry, ttl time.Duration, generation uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generation != generation {
		return
	}
	value.expiresAt = time.Now().Add(ttl)
	c.data[key] = value
}
