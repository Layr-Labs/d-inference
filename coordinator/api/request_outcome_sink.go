package api

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// A separate queue keeps heavy profiler and routing-telemetry loss independent
// of the compact unsampled ledger. No store IO or waiting on the request path.
type requestOutcomeSink struct {
	s        *Server
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

func newRequestOutcomeSink(s *Server, capacity int) *requestOutcomeSink {
	q := &requestOutcomeSink{s: s, ch: make(chan store.RequestOutcomeRecord, capacity), stop: make(chan struct{}), done: make(chan struct{})}
	go q.run()
	return q
}
func (q *requestOutcomeSink) submit(r store.RequestOutcomeRecord) {
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
	q.s.ddIncr("request_outcomes.records", []string{"status:dropped"})
}
func (q *requestOutcomeSink) close() {
	if q == nil {
		return
	}
	q.mu.Lock()
	if !q.closed {
		q.closed = true
		close(q.stop)
	}
	q.mu.Unlock()
	select {
	case <-q.done:
	case <-time.After(2 * time.Second):
		if q.s.logger != nil {
			q.s.logger.Warn("request outcomes drain incomplete", "dropped", q.dropped.Load(), "queued", len(q.ch))
		}
	}
}
func (q *requestOutcomeSink) run() {
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
			return q.s.store.RecordRequestOutcomes(ctx, batch)
		}()
		cancel()
		if err != nil {
			q.failed.Add(int64(len(batch)))
			q.s.ddCount("request_outcomes.records", int64(len(batch)), []string{"status:write_failed"})
			if q.s.logger != nil {
				q.s.logger.Warn("request outcomes persistence failed", "records", len(batch))
			}
		} else {
			q.written.Add(int64(len(batch)))
			q.s.ddCount("request_outcomes.records", int64(len(batch)), []string{"status:written"})
		}
		clear(batch)
		batch = batch[:0]
	}
	for {
		select {
		case r := <-q.ch:
			batch = append(batch, r)
			if len(batch) == cap(batch) {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-q.stop:
			for {
				select {
				case r := <-q.ch:
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
