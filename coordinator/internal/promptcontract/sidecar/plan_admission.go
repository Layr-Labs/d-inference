package sidecar

import (
	"context"
	"sync"
)

const (
	DefaultMaxConcurrency = 4
	// These bounds include active calls. Waiters retain caller-owned input,
	// but do not serialize another copy until a worker slot is available.
	MaxPendingPlans           = 64
	MaxPendingPlanBytes int64 = 64 << 20
)

// PlanAdmission bounds the client's planning work: at most Workers calls run,
// and at most MaxPendingPlans calls retaining MaxPendingPlanBytes accounted
// bytes wait or run.
type PlanAdmission struct {
	active  chan struct{}
	mu      sync.Mutex
	pending int
	bytes   int64
}

func NewPlanAdmission(workers int) *PlanAdmission {
	return &PlanAdmission{active: make(chan struct{}, workers)}
}

// Acquire bounds both retained payloads and work. The context is created at
// Plan entry and is never restarted after waiting or serialization.
func (a *PlanAdmission) Acquire(ctx context.Context, bytes int64) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if cap(a.active) == 0 {
		return nil, ErrSidecarUnavailable
	}
	a.mu.Lock()
	if a.pending >= MaxPendingPlans || bytes > MaxPendingPlanBytes-a.bytes {
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

// Workers is the number of admitted calls that may run at once.
func (a *PlanAdmission) Workers() int { return cap(a.active) }

// ActivePlans is the number of admitted calls holding a worker slot.
func (a *PlanAdmission) ActivePlans() int { return len(a.active) }

// PendingPlans is the number of admitted calls, waiting or active.
func (a *PlanAdmission) PendingPlans() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.pending
}

// PendingBytes is the accounted input retained by admitted calls.
func (a *PlanAdmission) PendingBytes() int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.bytes
}
