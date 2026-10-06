package outcomes

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// A separate queue keeps heavy profiler and routing-telemetry loss independent
// of the compact unsampled ledger. No store IO or waiting on the request path.
type Dependencies struct {
	Store interface {
		RecordRequestOutcomes(context.Context, []store.RequestOutcomeRecord) error
	}
	Logger *slog.Logger
	Incr   func(string, []string)
	Count  func(string, int64, []string)
}

type Queue struct {
	ch      chan store.RequestOutcomeRecord
	stop    chan struct{}
	mu      sync.RWMutex
	closed  bool
	dropped atomic.Int64
	incr    func(string, []string)
}

type Sink struct {
	queue    *Queue
	deps     Dependencies
	done     chan struct{}
	received atomic.Int64
	written  atomic.Int64
	failed   atomic.Int64
}

func NewQueue(capacity int, incr func(string, []string)) *Queue {
	return &Queue{ch: make(chan store.RequestOutcomeRecord, capacity), stop: make(chan struct{}), incr: incr}
}

func New(deps Dependencies, capacity int) *Sink {
	q := &Sink{queue: NewQueue(capacity, deps.Incr), deps: deps, done: make(chan struct{})}
	go q.run()
	return q
}
func (q *Queue) Submit(r store.RequestOutcomeRecord) {
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
	if q.incr != nil {
		q.incr("request_outcomes.records", []string{"status:dropped"})
	}
}
func (q *Queue) Close() {
	if q == nil {
		return
	}
	q.mu.Lock()
	if !q.closed {
		q.closed = true
		close(q.stop)
	}
	q.mu.Unlock()
}

type Stats struct {
	Received, Dropped, Written, Failed int64
	Depth                              int
}

func (q *Queue) Stats() Stats {
	if q == nil {
		return Stats{}
	}
	return Stats{Dropped: q.dropped.Load(), Depth: len(q.ch)}
}
func (q *Sink) Stats() Stats {
	if q == nil {
		return Stats{}
	}
	s := q.queue.Stats()
	s.Received, s.Written, s.Failed = q.received.Load(), q.written.Load(), q.failed.Load()
	return s
}
func (q *Sink) Received() {
	if q != nil {
		q.received.Add(1)
	}
}
func (q *Sink) Submit(r store.RequestOutcomeRecord) {
	if q != nil {
		q.queue.Submit(r)
	}
}
func (q *Sink) Close() {
	if q == nil {
		return
	}
	q.queue.Close()
	select {
	case <-q.done:
	case <-time.After(2 * time.Second):
		if q.deps.Logger != nil {
			q.deps.Logger.Warn("request outcomes drain incomplete", "dropped", q.Stats().Dropped, "queued", q.Stats().Depth)
		}
	}
}
func (q *Sink) run() {
	defer close(q.done)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	batch := make([]store.RequestOutcomeRecord, 0, 128)
	flush := func() {
		if len(batch) == 0 {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := func() (err error) {
			defer func() {
				if recover() != nil {
					err = errors.New("request outcome store panic")
				}
			}()
			return q.deps.Store.RecordRequestOutcomes(ctx, batch)
		}()
		cancel()
		if err != nil {
			q.failed.Add(int64(len(batch)))
			if q.deps.Count != nil {
				q.deps.Count("request_outcomes.records", int64(len(batch)), []string{"status:write_failed"})
			}
			if q.deps.Logger != nil {
				q.deps.Logger.Warn("request outcomes persistence failed", "records", len(batch))
			}
		} else {
			q.written.Add(int64(len(batch)))
			if q.deps.Count != nil {
				q.deps.Count("request_outcomes.records", int64(len(batch)), []string{"status:written"})
			}
		}
		clear(batch)
		batch = batch[:0]
	}
	for {
		select {
		case r := <-q.queue.ch:
			batch = append(batch, r)
			if len(batch) == cap(batch) {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-q.queue.stop:
			for {
				select {
				case r := <-q.queue.ch:
					batch = append(batch, r)
					if len(batch) == cap(batch) {
						flush()
					}
				default:
					flush()
					return
				}
			}
		}
	}
}
