package outcomequeue

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"log/slog"
	"sync"
	"sync/atomic"
)

// Hooks inject the context-aware write and optional diagnostics. Write must
// resolve the active store at call time; the queue never retains a Server.
type Hooks struct {
	Logger *slog.Logger
	Write  func(context.Context, []store.RequestOutcomeRecord) error
	Incr   func(string, []string)
	Count  func(string, int64, []string)
}

// Sink keeps compact outcome loss independent of heavy profiles and routing
// telemetry. Its mutex orders Submit against Close; counters remain private.
type Sink struct {
	hooks    Hooks
	ch       chan store.RequestOutcomeRecord
	stop     chan struct{}
	done     chan struct{}
	mu       sync.RWMutex
	closed   bool
	received atomic.Int64
	dropped  atomic.Int64
	written  atomic.Int64
	failed   atomic.Int64
}

func New(hooks Hooks, capacity int) *Sink {
	q := &Sink{hooks: hooks, ch: make(chan store.RequestOutcomeRecord, capacity), stop: make(chan struct{}), done: make(chan struct{})}
	go q.run()
	return q
}

// Submit takes the caller's already-owned snapshot without waiting for IO.
// A full or closed queue drops and counts it; inference remains unaffected.
func (q *Sink) Submit(r store.RequestOutcomeRecord) {
	if q == nil {
		return
	}
	q.mu.RLock()
	defer q.mu.RUnlock()
	if !q.closed {
		select {
		case q.ch <- r:
			return
		default:
		}
	}
	q.dropped.Add(1)
	if q.hooks.Incr != nil {
		q.hooks.Incr("request_outcomes.records", []string{"status:dropped"})
	}
}
