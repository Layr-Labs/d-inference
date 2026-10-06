// Package authcache memoizes credential lookups and fences publication across mutations.
package authcache

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	TTL        = 60 * time.Second
	MaxEntries = 1000
)

type entry struct {
	key      *store.APIKey
	cachedAt time.Time
}

type Cache struct {
	mu         sync.RWMutex
	entries    map[string]entry
	generation uint64
	now        func() time.Time
}

func New(now func() time.Time) *Cache {
	return &Cache{entries: make(map[string]entry), now: now}
}

// Lookup returns the generation to use when publishing a database lookup on a miss.
// A nil key with ok=true is a cached negative result.
func (c *Cache) Lookup(token string) (key *store.APIKey, generation uint64, ok bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	e, ok := c.entries[token]
	if !ok || c.now().Sub(e.cachedAt) > TTL {
		return nil, c.generation, false
	}
	return e.key, c.generation, true
}

// Publish rejects results read before an intervening credential mutation.
func (c *Cache) Publish(token string, key *store.APIKey, generation uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if generation != c.generation {
		return false
	}
	if _, exists := c.entries[token]; !exists && len(c.entries) >= MaxEntries {
		var oldest string
		var oldestTime time.Time
		for k, v := range c.entries {
			if oldestTime.IsZero() || v.cachedAt.Before(oldestTime) {
				oldest, oldestTime = k, v.cachedAt
			}
		}
		delete(c.entries, oldest)
	}
	c.entries[token] = entry{key: key, cachedAt: c.now()}
	return true
}

func (c *Cache) Invalidate(token string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.generation++
	delete(c.entries, token)
}

func (c *Cache) InvalidateAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.generation++
	c.entries = make(map[string]entry)
}
