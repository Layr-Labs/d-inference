// Package flight is state the overlay names by *type* rather than by field: its
// own fields are absorbed by the package default, so the receiver is the only
// place the map can attach a node. Its filling method carries no verb ("Do"), so
// the shape of the statements inside it is the sole evidence of what it does to
// the cache — the shape a real coalescing cache has.
package flight

import "sync"

// Cache is concurrent state, so the state-holder check requires a decision about
// it; deps.types supplies one for the type while its fields stay defaulted.
type Cache struct {
	mu      sync.Mutex
	entries map[string]string
}

func New() *Cache {
	return &Cache{entries: make(map[string]string)}
}

// Do answers from the cache, filling it on a miss. The fill writes *through* a
// field the overlay skips (`c.entries[key] = ...`), which is exactly the case a
// walk that reads the base of a write target as a read would publish read-only.
func (c *Cache) Do(key string, fill func() string) string {
	c.mu.Lock()
	hit, ok := c.entries[key]
	c.mu.Unlock()
	if ok {
		return hit
	}
	value := fill()
	c.mu.Lock()
	c.entries[key] = value
	c.mu.Unlock()
	return value
}
