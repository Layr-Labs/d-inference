package modelindex

import (
	"sync"
	"sync/atomic"
)

// Counts tracks live provider advertisements independently of catalog-filtered
// fleet projections. Its lock is a leaf lock beneath registry/provider locks.
type Counts struct {
	mu     sync.Mutex
	models map[string]*atomic.Int64
}

func (c *Counts) Add(model string) {
	c.mu.Lock()
	count, ok := c.models[model]
	if !ok {
		count = &atomic.Int64{}
		if c.models == nil {
			c.models = make(map[string]*atomic.Int64)
		}
		c.models[model] = count
	}
	c.mu.Unlock()
	count.Add(1)
}

func (c *Counts) Remove(model string) {
	c.mu.Lock()
	count, ok := c.models[model]
	c.mu.Unlock()
	if ok {
		if count.Add(-1) <= 0 {
			c.mu.Lock()
			delete(c.models, model)
			c.mu.Unlock()
		}
	}
}

func (c *Counts) Count(model string) int64 {
	c.mu.Lock()
	count := c.models[model]
	c.mu.Unlock()
	if count == nil {
		return 0
	}
	return count.Load()
}
