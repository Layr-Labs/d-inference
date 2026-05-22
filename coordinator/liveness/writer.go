// Package liveness records historical provider heartbeats and session
// intervals to the store. It exists so the coordinator's heartbeat hot path
// can be non-blocking: the WebSocket handler emits an in-memory event, and
// a background goroutine batches and bulk-INSERTs them via the store.
//
// Safeguards (see plan: /plans/what-i-d-extend-given-crispy-rivest.md):
//   - bounded channel + non-blocking send (drops on overflow, counts drops)
//   - batched flush every flushInterval OR when buffer reaches batchSize
//   - per-flush statement timeout via context
//   - error backoff (skip next tick on failure)
//   - graceful drain on Close with a configurable deadline
package liveness

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Defaults — picked from the plan, tunable via Config.
const (
	defaultBufferSize    = 8192
	defaultBatchSize     = 500
	defaultFlushInterval = 2 * time.Second
	defaultFlushTimeout  = 5 * time.Second
	defaultErrorBackoff  = 2 // skip this many ticks after a failure
	defaultDrainTimeout  = 10 * time.Second
)

// Config tunes the Writer's batching behavior.
type Config struct {
	BufferSize    int           // channel capacity; events emitted when full are dropped
	BatchSize     int           // flush early when buffer reaches this size
	FlushInterval time.Duration // periodic flush tick
	FlushTimeout  time.Duration // statement timeout per flush
	DrainTimeout  time.Duration // max time to wait on Close()
}

func (c Config) withDefaults() Config {
	if c.BufferSize <= 0 {
		c.BufferSize = defaultBufferSize
	}
	if c.BatchSize <= 0 {
		c.BatchSize = defaultBatchSize
	}
	if c.FlushInterval <= 0 {
		c.FlushInterval = defaultFlushInterval
	}
	if c.FlushTimeout <= 0 {
		c.FlushTimeout = defaultFlushTimeout
	}
	if c.DrainTimeout <= 0 {
		c.DrainTimeout = defaultDrainTimeout
	}
	return c
}

// CounterFn is the interface the Writer uses to publish stats. Implementations
// typically wrap api.Metrics.IncCounter. Nil counters are silently ignored so
// callers don't have to wire anything up in tests.
type CounterFn func(name string, value int64)

// Writer buffers HeartbeatEvents and flushes them to the store in batches.
// Safe for concurrent Emit() callers.
type Writer struct {
	cfg    Config
	store  store.Store
	logger *slog.Logger
	count  CounterFn

	events chan store.HeartbeatEvent

	// Lifecycle.
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	closeOnce sync.Once

	// Stats (exported via Stats() for tests + metrics).
	dropped      atomic.Int64
	flushed      atomic.Int64
	flushFailed  atomic.Int64
	lastFlushErr atomic.Pointer[error]
}

// NewWriter constructs a Writer but does not start its flush goroutine.
// Call Start to begin batching.
func NewWriter(s store.Store, logger *slog.Logger, count CounterFn, cfg Config) *Writer {
	cfg = cfg.withDefaults()
	if logger == nil {
		logger = slog.Default()
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Writer{
		cfg:    cfg,
		store:  s,
		logger: logger.With("component", "liveness.writer"),
		count:  count,
		events: make(chan store.HeartbeatEvent, cfg.BufferSize),
		ctx:    ctx,
		cancel: cancel,
	}
}

// Start launches the background flush goroutine. Safe to call once.
func (w *Writer) Start() {
	w.wg.Add(1)
	saferun.Go(w.logger, "liveness.writer.flush", func() {
		defer w.wg.Done()
		w.flushLoop()
	})
}

// Emit enqueues a heartbeat event for asynchronous persistence. Never blocks:
// if the buffer is full the event is dropped and the drop counter is bumped.
// This is the function called from the heartbeat hot path on every heartbeat.
func (w *Writer) Emit(ev store.HeartbeatEvent) {
	select {
	case w.events <- ev:
	default:
		n := w.dropped.Add(1)
		w.incCounter("liveness_dropped_total", 1)
		// Rate-limit the log to once every 1024 drops so a flood doesn't drown
		// out other coordinator logs.
		if n&1023 == 1 {
			w.logger.Warn("liveness writer dropping events — buffer full",
				"dropped_total", n,
				"buffer_size", w.cfg.BufferSize)
		}
	}
}

// Stats is a snapshot of writer counters for tests and metrics scraping.
type Stats struct {
	Dropped     int64
	Flushed     int64
	FlushFailed int64
	Buffered    int
}

// Stats returns a point-in-time snapshot of the writer counters.
func (w *Writer) Stats() Stats {
	return Stats{
		Dropped:     w.dropped.Load(),
		Flushed:     w.flushed.Load(),
		FlushFailed: w.flushFailed.Load(),
		Buffered:    len(w.events),
	}
}

// Close stops the flush loop, draining any buffered events with a deadline
// of cfg.DrainTimeout. Safe to call multiple times; only the first does work.
// After Close, Emit() will still accept events but they will never be flushed.
func (w *Writer) Close() {
	w.closeOnce.Do(func() {
		// Signal the flush loop to drain + exit. It owns the channel close.
		w.cancel()
		// Wait for the loop to finish, bounded by DrainTimeout.
		done := make(chan struct{})
		go func() {
			w.wg.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(w.cfg.DrainTimeout):
			w.logger.Warn("liveness writer drain timed out",
				"deadline", w.cfg.DrainTimeout,
				"buffered", len(w.events))
		}
	})
}

// flushLoop is the background goroutine that batches events and writes them
// to the store. It exits when ctx is cancelled (via Close), draining the
// channel before returning.
func (w *Writer) flushLoop() {
	ticker := time.NewTicker(w.cfg.FlushInterval)
	defer ticker.Stop()

	batch := make([]store.HeartbeatEvent, 0, w.cfg.BatchSize)
	backoff := 0 // ticks to skip after an error

	flush := func() {
		if len(batch) == 0 {
			return
		}
		if backoff > 0 {
			// Still in error window; defer this batch to the next tick.
			backoff--
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), w.cfg.FlushTimeout)
		defer cancel()
		if err := w.store.AppendHeartbeats(ctx, batch); err != nil {
			w.flushFailed.Add(1)
			w.incCounter("liveness_flush_failed_total", 1)
			w.lastFlushErr.Store(&err)
			w.logger.Warn("liveness flush failed",
				"error", err,
				"batch_size", len(batch))
			backoff = defaultErrorBackoff
			// Keep the batch so a fast catch-up can retry next tick.
			return
		}
		w.flushed.Add(int64(len(batch)))
		w.incCounter("liveness_flush_rows_total", int64(len(batch)))
		batch = batch[:0]
	}

	for {
		select {
		case ev := <-w.events:
			batch = append(batch, ev)
			if len(batch) >= w.cfg.BatchSize {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-w.ctx.Done():
			// Drain whatever remains in the channel into the batch (bounded
			// by DrainTimeout via the outer select in Close). Force-clear the
			// error backoff so we make a best-effort final flush even if the
			// last steady-state flush failed within the backoff window —
			// otherwise drain silently drops the buffered tail.
			backoff = 0
			for {
				select {
				case ev := <-w.events:
					batch = append(batch, ev)
				default:
					flush()
					return
				}
				if len(batch) >= w.cfg.BatchSize {
					flush()
				}
			}
		}
	}
}

func (w *Writer) incCounter(name string, value int64) {
	if w.count != nil {
		w.count(name, value)
	}
}
