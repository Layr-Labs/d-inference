package api

// Non-blocking sink for best-effort routing-telemetry persistence.
//
// Routing telemetry (inference-route records, outcome updates, rejection ledger
// rows) is observability data: useful, but it must NEVER add latency or
// backpressure to inference, and it must never let a slow/unavailable store
// (Postgres) grow goroutines or memory without bound. Previously each telemetry
// write was persisted with its own saferun.Go(...) goroutine — one goroutine per
// write. When the store fell behind, those goroutines (each pinning the captured
// record) piled up unboundedly.
//
// telemetrySink replaces that with a single bounded, non-blocking queue: the
// request path enqueues a closure via submit (which never blocks), a small fixed
// pool of long-lived workers drains the queue, and when the buffer is full the
// write is DROPPED and counted. Goroutines and memory are therefore bounded by
// construction, and inference latency is fully decoupled from store latency.

import (
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Sink defaults. The buffer absorbs brief store stalls without dropping, while
// the small fixed worker pool caps the goroutines (and concurrent store calls)
// telemetry can ever consume. Both are deliberately modest — telemetry is
// best-effort and must not compete with inference for resources.
const (
	defaultTelemetrySinkCapacity = 4096
	defaultTelemetrySinkWorkers  = 2
)

// telemetrySink is a bounded, non-blocking work queue for best-effort telemetry
// persistence. submit enqueues a closure without blocking; a fixed pool of
// long-lived workers drains the queue and runs each closure inside a panic-safe
// wrapper. When the buffer is full the write is dropped and counted, so the
// inference path can never be slowed or blocked by telemetry — even if the store
// is slow or down — and goroutine/memory growth is bounded.
type telemetrySink struct {
	ch      chan func()
	done    chan struct{}
	logger  *slog.Logger
	dropped atomic.Int64
	// closeOnce makes close idempotent: done is closed exactly once even when
	// close is reached from more than one shutdown path.
	closeOnce sync.Once
}

// newTelemetrySink starts workers long-lived goroutines, each draining the
// buffered work channel until the sink is closed. capacity and workers fall back
// to the package defaults when non-positive.
func newTelemetrySink(logger *slog.Logger, capacity, workers int) *telemetrySink {
	if capacity <= 0 {
		capacity = defaultTelemetrySinkCapacity
	}
	if workers <= 0 {
		workers = defaultTelemetrySinkWorkers
	}
	t := &telemetrySink{
		ch:     make(chan func(), capacity),
		done:   make(chan struct{}),
		logger: logger,
	}
	for i := 0; i < workers; i++ {
		go t.worker()
	}
	return t
}

// worker drains the work channel until the sink is closed. The worker IS the
// long-lived goroutine — it runs each task inline (inside a panic-safe wrapper)
// and never spawns a goroutine per task.
func (t *telemetrySink) worker() {
	for {
		select {
		case fn := <-t.ch:
			t.run(fn)
		case <-t.done:
			return
		}
	}
}

// run executes one telemetry closure with saferun's recover semantics (log +
// observe a panic, never propagate it). It reuses saferun.Recover rather than
// saferun.Go precisely so no new goroutine is spawned per task.
func (t *telemetrySink) run(fn func()) {
	defer saferun.Recover(t.logger, "telemetrySink")
	if fn != nil {
		fn()
	}
}

// submit enqueues fn without ever blocking. It returns true when the work was
// accepted, or false when the buffer was full — in which case the write is
// dropped and the drop counter is incremented. The inference request path calls
// this, so it must never block.
func (t *telemetrySink) submit(fn func()) bool {
	if t == nil || fn == nil {
		return false
	}
	select {
	case t.ch <- fn:
		return true
	default:
		n := t.dropped.Add(1)
		t.maybeLogDrop(n)
		return false
	}
}

// close signals the workers to stop and is idempotent. It never blocks on
// in-flight telemetry writes: a stuck store call (the exact failure this sink
// guards against) must not be able to stall coordinator shutdown. Workers return
// on their next loop iteration once done is closed; any buffered-but-unrun
// telemetry is best-effort and discarded.
func (t *telemetrySink) close() {
	if t == nil {
		return
	}
	t.closeOnce.Do(func() {
		close(t.done)
	})
}

// maybeLogDrop emits a throttled warning so operators notice sustained drops
// without flooding logs: it logs only when the cumulative drop count crosses a
// power of ten (1, 10, 100, 1000, …).
func (t *telemetrySink) maybeLogDrop(total int64) {
	if t.logger == nil || !isPowerOfTen(total) {
		return
	}
	t.logger.Warn("routing telemetry sink dropping writes (buffer full) — inference is unaffected",
		"dropped_total", total,
		"capacity", cap(t.ch),
	)
}

// isPowerOfTen reports whether n is 1, 10, 100, 1000, … It is the throttle key
// for drop logging.
func isPowerOfTen(n int64) bool {
	if n < 1 {
		return false
	}
	for n%10 == 0 {
		n /= 10
	}
	return n == 1
}
