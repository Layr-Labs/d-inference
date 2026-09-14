package warmpool

import (
	"sync"
	"time"
)

type queuePressureState struct {
	mu     sync.Mutex
	models map[string]QueuePressure
}

type QueuePressure struct {
	Depth     int
	OldestAge time.Duration
	UpdatedAt time.Time
}

func (c *Controller[A]) RecordQueuePressure(model string, depth int, oldestAge time.Duration, now time.Time) {
	c.queueMu.mu.Lock()
	defer c.queueMu.mu.Unlock()
	if depth <= 0 {
		delete(c.queueMu.models, model)
		return
	}
	if oldestAge < 0 {
		oldestAge = 0
	}
	c.queueMu.models[model] = QueuePressure{Depth: depth, OldestAge: oldestAge, UpdatedAt: now}
}

func (c *Controller[A]) queueSnapshot(now time.Time, recentWindow time.Duration) map[string]QueuePressure {
	c.queueMu.mu.Lock()
	defer c.queueMu.mu.Unlock()
	out := make(map[string]QueuePressure, len(c.queueMu.models))
	for model, p := range c.queueMu.models {
		if !p.UpdatedAt.IsZero() && now.Sub(p.UpdatedAt) > recentWindow {
			delete(c.queueMu.models, model)
			continue
		}
		out[model] = p
	}
	return out
}
