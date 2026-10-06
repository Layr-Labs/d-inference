package queuedrain

import "sync"

// Coalescer retains one consumer claim per model. A trigger arriving while the
// pass holds popped waiters records a rerun, rather than draining an empty queue.
// The zero value is ready to use.
type Coalescer struct {
	mu      sync.Mutex
	running map[string]bool
	rerun   map[string]string
}

func (c *Coalescer) Begin(model, reason string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.running[model] {
		if c.rerun == nil {
			c.rerun = make(map[string]string)
		}
		c.rerun[model] = reason
		return false
	}
	if c.running == nil {
		c.running = make(map[string]bool)
	}
	c.running[model] = true
	return true
}

// End keeps the claim when another trigger arrived, returning its attribution.
func (c *Coalescer) End(model string) (reason string, again bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if reason, ok := c.rerun[model]; ok {
		delete(c.rerun, model)
		return reason, true
	}
	delete(c.running, model)
	return "", false
}

// Abandon releases a pass that unwound without requeueing and completing.
func (c *Coalescer) Abandon(model string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.running, model)
	delete(c.rerun, model)
}
