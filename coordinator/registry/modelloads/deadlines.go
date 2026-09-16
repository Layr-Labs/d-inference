package modelloads

import "time"

// Expire removes only deadlines strictly before now. Equality is deliberately
// retained here even though a status receipt requires a strictly live deadline.
func (c *Commands) Expire(now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for key, expiresAt := range c.pending {
		if now.After(expiresAt) {
			delete(c.pending, key)
			delete(c.started, key)
		}
	}
}

// Count performs the same expiry sweep before reporting global load pressure.
func (c *Commands) Count(now time.Time) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	count := 0
	for key, expiresAt := range c.pending {
		if now.After(expiresAt) {
			delete(c.pending, key)
			delete(c.started, key)
			continue
		}
		count++
	}
	return count
}

// Observe copies one command's clocks without exposing either mutable map.
type Status struct {
	ExpiresAt, StartedAt time.Time
	Pending, Started     bool
}

func (c *Commands) Observe(providerID, modelID string) Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	k := key{ProviderID: providerID, ModelID: modelID}
	expires, pending := c.pending[k]
	started, hasStarted := c.started[k]
	return Status{ExpiresAt: expires, StartedAt: started, Pending: pending, Started: hasStarted}
}

// Complete clears both records and returns the original start observation.
// The registry preserves its duration clock read after releasing registry locks.
func (c *Commands) Complete(providerID, modelID string) time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	k := key{ProviderID: providerID, ModelID: modelID}
	started := c.started[k]
	delete(c.pending, k)
	delete(c.started, k)
	return started
}

func (c *Commands) Backoff(providerID, modelID string, backoff time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pending == nil {
		c.pending = make(map[key]time.Time)
	}
	if c.started == nil {
		c.started = make(map[key]time.Time)
	}
	k := key{ProviderID: providerID, ModelID: modelID}
	now := time.Now()
	c.pending[k] = now.Add(backoff)
	if c.started[k].IsZero() {
		c.started[k] = now
	}
}
