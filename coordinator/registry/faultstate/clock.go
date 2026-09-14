package faultstate

import (
	"log/slog"
	"time"
)

// NewWithClock binds a lifecycle clock at construction. Callers must not change
// the function itself after the manager is published. A nil clock uses time.Now.
// The clock must be concurrency-safe and must not acquire registry/provider
// locks: transactions read it while holding a gate. Wait-duration telemetry
// always uses the real monotonic clock.
func NewWithClock[C comparable](logger *slog.Logger, now func() time.Time) Manager[C] {
	return newManager[C](logger, now)
}
func (r *Manager[C]) now() time.Time {
	if r.clock != nil {
		return r.clock()
	}
	return time.Now()
}
