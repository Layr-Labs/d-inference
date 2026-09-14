package readcache

import (
	"sync"
	"time"
)

// Refresher coalesces computations for one cache entry. Its zero value is
// ready to use; callers must consistently pair it with the same cache and key.
type Refresher struct {
	mu       sync.Mutex
	inflight chan struct{}
}

// Get fills a cold entry. It rechecks under the flight lock so a caller delayed
// after its initial miss cannot repeat a query that another caller completed.
// On a computation error it returns any still-valid prior value. The compute
// callback owns error reporting and runs once per flight.
func (r *Refresher) Get(c *Cache, key string, ttl time.Duration, compute func() ([]byte, error)) ([]byte, bool) {
	return r.compute(c, key, ttl, false, compute)
}

// Refresh forces a refresh even before expiry, sharing an existing flight.
// Failed computations never overwrite the previous success or extend its TTL.
func (r *Refresher) Refresh(c *Cache, key string, ttl time.Duration, compute func() ([]byte, error)) ([]byte, bool) {
	return r.compute(c, key, ttl, true, compute)
}

func (r *Refresher) compute(c *Cache, key string, ttl time.Duration, refresh bool, compute func() ([]byte, error)) ([]byte, bool) {
	r.mu.Lock()
	if !refresh {
		if body, ok := c.Get(key); ok {
			r.mu.Unlock()
			return body, true
		}
	}
	if wait := r.inflight; wait != nil {
		r.mu.Unlock()
		<-wait
		body, ok := c.Get(key)
		return body, ok
	}

	done := make(chan struct{})
	r.inflight = done
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		r.inflight = nil
		close(done)
		r.mu.Unlock()
	}()

	body, err := compute()
	if err != nil {
		previous, ok := c.Get(key)
		return previous, ok
	}
	c.Set(key, body, ttl)
	return body, true
}
