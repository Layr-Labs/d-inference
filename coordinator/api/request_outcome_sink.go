package api

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Request accounting has its own bounded unsampled sink. It cannot evict route
// or profile records. Loss is counted and never advertised as zero traffic or a
// complete traffic denominator. At most 64 compact snapshots per store call.
type requestOutcomeSink struct {
	s          *Server
	ch         chan *outcomes.Record
	done       chan struct{}
	stopped    chan struct{}
	mu         sync.RWMutex
	closed     bool
	shutdownAt time.Time
	dropped    atomic.Int64
}

func newRequestOutcomeSink(s *Server, capacity int) *requestOutcomeSink {
	if s.store == nil {
		return nil
	}
	if capacity <= 0 {
		capacity = 4096
	}
	p := &requestOutcomeSink{s: s, ch: make(chan *outcomes.Record, capacity), done: make(chan struct{}), stopped: make(chan struct{})}
	go p.run()
	go p.pruneLoop()
	return p
}

func (p *requestOutcomeSink) submit(r *outcomes.Record) {
	if p == nil || r == nil {
		return
	}
	p.mu.RLock()
	defer p.mu.RUnlock()
	if !p.closed {
		select {
		case p.ch <- r:
			return
		default:
		}
	}
	p.dropped.Add(1)
	p.s.ddIncr("request_outcomes.records", []string{"status:dropped"})
}

func (p *requestOutcomeSink) close() {
	if p == nil {
		return
	}
	p.mu.Lock()
	if !p.closed {
		p.closed = true
		p.shutdownAt = time.Now().Add(telemetrySinkShutdownFlush)
		close(p.done)
	}
	p.mu.Unlock()
	select {
	case <-p.stopped:
	case <-time.After(telemetrySinkShutdownFlush):
		p.s.ddIncr("request_outcomes.shutdown_unconfirmed", nil)
	}
}

func (p *requestOutcomeSink) flush(batch []*outcomes.Record) {
	if len(batch) == 0 {
		return
	}
	persisted := false
	defer func() {
		status := "written"
		if !persisted {
			status = "write_failed"
			p.dropped.Add(int64(len(batch)))
		}
		p.s.ddCount("request_outcomes.records", int64(len(batch)), []string{"status:" + status})
	}()
	defer saferun.Recover(p.s.logger, "requestOutcomeSink.flush")
	if err := p.s.store.RecordRequestOutcomes(batch); err != nil {
		if p.s.logger != nil {
			p.s.logger.Error("request outcome persistence failed", "rows", len(batch), "error", err)
		}
		return
	}
	persisted = true
}

func (p *requestOutcomeSink) run() {
	defer close(p.stopped)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	batch := make([]*outcomes.Record, 0, 64)
	for {
		select {
		case r := <-p.ch:
			batch = append(batch, r)
			if len(batch) == 64 {
				p.flush(batch)
				batch = batch[:0]
			}
		case <-tick.C:
			p.flush(batch)
			batch = batch[:0]
		case <-p.done:
			for {
				if time.Now().After(p.shutdownAt) {
					n := int64(len(batch) + len(p.ch))
					p.dropped.Add(n)
					p.s.ddCount("request_outcomes.records", n, []string{"status:shutdown_dropped"})
					return
				}
				select {
				case r := <-p.ch:
					batch = append(batch, r)
					if len(batch) == 64 {
						p.flush(batch)
						batch = batch[:0]
					}
				default:
					p.flush(batch)
					return
				}
			}
		}
	}
}

// Retention has a separate worker so deletion never blocks the accounting
// writer. Every minute it drains 5000-row transactions until caught up or the
// five-second budget expires; cancellation stops the scan during shutdown.
func (p *requestOutcomeSink) pruneLoop() {
	defer saferun.Recover(p.s.logger, "requestOutcomeSink.prune")
	timer := time.NewTicker(time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-p.done:
			return
		case <-timer.C:
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		before := time.Now().Add(-14 * 24 * time.Hour)
		for ctx.Err() == nil {
			select {
			case <-p.done:
				cancel()
				return
			default:
			}
			n, err := p.s.store.PruneRequestOutcomes(ctx, before, 5000)
			if err != nil {
				if p.s.logger != nil {
					p.s.logger.Warn("request outcome retention failed", "error", err)
				}
				break
			}
			if n < 5000 {
				break
			}
		}
		cancel()
	}
}
