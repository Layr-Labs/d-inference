package sidecar

import (
	"context"
	"sync"
)

const (
	DefaultMaxConcurrency = 4
	// These bounds include active calls. Waiters retain caller-owned input,
	// but do not serialize another copy until a worker slot is available.
	maxPendingPlans           = 64
	maxPendingPlanBytes int64 = 64 << 20
)

type planAdmission struct {
	active  chan struct{}
	mu      sync.Mutex
	pending int
	bytes   int64
}

func newPlanAdmission(workers int) *planAdmission {
	return &planAdmission{active: make(chan struct{}, workers)}
}

// acquire bounds both retained payloads and work. The context is created at
// Plan entry and is never restarted after waiting or serialization.
func (a *planAdmission) acquire(ctx context.Context, bytes int64) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if cap(a.active) == 0 {
		return nil, ErrSidecarUnavailable
	}
	a.mu.Lock()
	if a.pending >= maxPendingPlans || bytes > maxPendingPlanBytes-a.bytes {
		a.mu.Unlock()
		return nil, ErrSidecarUnavailable
	}
	a.pending++
	a.bytes += bytes
	a.mu.Unlock()
	refund := func() {
		a.mu.Lock()
		a.pending--
		a.bytes -= bytes
		a.mu.Unlock()
	}
	select {
	case a.active <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-a.active
			refund()
			return nil, err
		}
		return func() { <-a.active; refund() }, nil
	case <-ctx.Done():
		refund()
		return nil, ctx.Err()
	}
}
