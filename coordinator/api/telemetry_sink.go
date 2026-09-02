package api

// Non-blocking, batching sink for best-effort routing-telemetry persistence.
//
// Routing telemetry (inference-route records, outcome updates, rejection ledger
// rows) is observability data: useful, but it must NEVER add latency or
// backpressure to inference, and it must never let a slow/unavailable store
// (Postgres) grow goroutines or memory without bound. Previously each telemetry
// write was persisted with its own saferun.Go(...) goroutine — one goroutine per
// write. When the store fell behind, those goroutines (each pinning the captured
// record) piled up unboundedly.
//
// telemetrySink is a single bounded, non-blocking queue: the request path
// enqueues an op (which never blocks), a small fixed pool of long-lived workers
// drains the queue, and when the buffer is full the write is DROPPED and
// counted. Goroutines and memory are therefore bounded by construction, and
// inference latency is fully decoupled from store latency.
//
// Ops are TYPED so the worker can coalesce them: a worker gathers up to
// maxBatch ops (waiting at most window for more), writes every route record in
// the group with ONE multi-row store call and every run of outcome updates with
// ONE pipelined call, and runs generic closures (rejections) inline at their
// queue position. See telemetry_sink_batch.go for the ordering argument.

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Sink defaults. The buffer absorbs brief store stalls without dropping, while
// one worker preserves route insert -> outcome update ordering for a given
// request without adding request latency: callers still only enqueue work into
// the bounded channel. Telemetry is best-effort and must not compete with
// inference for resources.
//
// maxBatch/window bound one worker group: at most 256 ops per group, and a
// group is flushed no later than 100ms after its first op even when the queue
// is quiet. 256 records × 57 columns stays well inside one INSERT statement.
const (
	defaultTelemetrySinkCapacity    = 4096
	defaultTelemetrySinkWorkers     = 1
	defaultTelemetrySinkMaxBatch    = 256
	defaultTelemetrySinkBatchWindow = 100 * time.Millisecond
)

// telemetryOp is one queued unit of telemetry work. Exactly one of fn, record,
// or update is set.
type telemetryOp struct {
	// fn is a generic best-effort closure (rejection ledger rows, ...). It runs
	// at its queue position and is never reordered relative to other closures.
	fn func()
	// record is an inference_routes snapshot insert (upsert on request/attempt).
	record *store.InferenceRouteRecord
	// update is an outcome merge onto an existing inference_routes row.
	update *store.InferenceRouteOutcomeUpdate
	// model tags the update's failure log line; it is diagnostic only.
	model string
}

// telemetrySink is a bounded, non-blocking work queue for best-effort telemetry
// persistence. submit* enqueue without blocking; a fixed pool of long-lived
// workers drains the queue in coalesced groups, running each store call inside
// a panic-safe wrapper. When the buffer is full the write is dropped and
// counted, so the inference path can never be slowed or blocked by telemetry —
// even if the store is slow or down — and goroutine/memory growth is bounded.
type telemetrySink struct {
	ch      chan telemetryOp
	done    chan struct{}
	logger  *slog.Logger
	dropped atomic.Int64
	// closeOnce makes close idempotent: done is closed exactly once even when
	// close is reached from more than one shutdown path.
	closeOnce sync.Once

	// maxBatch caps the ops gathered into one worker group; window caps how
	// long a worker waits for more ops after the group's first one.
	maxBatch int
	window   time.Duration

	// store persists typed ops (records, updates). It is bound once by the
	// first typed submit (bind); the channel send/receive orders that write
	// before any worker read, so no lock is needed on the read side.
	store    store.TelemetryStore
	bindOnce sync.Once

	// workers counts live worker goroutines so closeAndWait can observe the
	// final drain (tests); close itself never waits.
	workers sync.WaitGroup
}

// newTelemetrySink starts workers long-lived goroutines with the default
// batching parameters. capacity and workers fall back to the package defaults
// when non-positive.
func newTelemetrySink(logger *slog.Logger, capacity, workers int) *telemetrySink {
	return newBatchingTelemetrySink(logger, capacity, workers, defaultTelemetrySinkMaxBatch, defaultTelemetrySinkBatchWindow)
}

// newBatchingTelemetrySink is newTelemetrySink with explicit group bounds.
// maxBatch 1 disables coalescing (every op is its own group, no window wait).
// Non-positive values fall back to the package defaults.
func newBatchingTelemetrySink(logger *slog.Logger, capacity, workers, maxBatch int, window time.Duration) *telemetrySink {
	if capacity <= 0 {
		capacity = defaultTelemetrySinkCapacity
	}
	if workers <= 0 {
		workers = defaultTelemetrySinkWorkers
	}
	if maxBatch <= 0 {
		maxBatch = defaultTelemetrySinkMaxBatch
	}
	if window <= 0 {
		window = defaultTelemetrySinkBatchWindow
	}
	t := &telemetrySink{
		ch:       make(chan telemetryOp, capacity),
		done:     make(chan struct{}),
		logger:   logger,
		maxBatch: maxBatch,
		window:   window,
	}
	t.workers.Add(workers)
	for i := 0; i < workers; i++ {
		go t.worker()
	}
	return t
}

// bind sets the store that persists typed ops. The first call wins; later
// calls are no-ops. Callers must bind before their first typed submit (the
// Server helpers in route_telemetry_submit.go do this on every submit, which
// is a cheap sync.Once check after the first).
func (t *telemetrySink) bind(st store.TelemetryStore) {
	if t == nil {
		return
	}
	t.bindOnce.Do(func() { t.store = st })
}

// submit enqueues a generic closure without ever blocking. It returns true
// when the work was accepted, or false when the buffer was full — in which
// case the write is dropped and the drop counter is incremented. The inference
// request path calls this, so it must never block.
func (t *telemetrySink) submit(fn func()) bool {
	if t == nil || fn == nil {
		return false
	}
	return t.enqueue(telemetryOp{fn: fn})
}

// submitRoute enqueues an inference_routes snapshot insert. Same non-blocking
// accept/drop contract as submit.
func (t *telemetrySink) submitRoute(record *store.InferenceRouteRecord) bool {
	if t == nil || record == nil {
		return false
	}
	return t.enqueue(telemetryOp{record: record})
}

// submitOutcome enqueues an outcome merge for (requestID, attempt). Same
// non-blocking accept/drop contract as submit. The caller guarantees the
// matching submitRoute happened-before this call (dispatch precedes every
// commit/terminal), which is what lets the worker write records before
// updates inside one group.
func (t *telemetrySink) submitOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) bool {
	if t == nil || outcome == nil {
		return false
	}
	return t.enqueue(telemetryOp{
		update: &store.InferenceRouteOutcomeUpdate{RequestID: requestID, Attempt: attempt, Outcome: outcome},
		model:  model,
	})
}

// enqueue is the single non-blocking entry into the buffer: accept, or drop
// and count.
func (t *telemetrySink) enqueue(op telemetryOp) bool {
	select {
	case t.ch <- op:
		return true
	default:
		n := t.dropped.Add(1)
		t.maybeLogDrop(n)
		return false
	}
}

// close signals the workers to stop and is idempotent. It never blocks on
// in-flight telemetry writes: a stuck store call (the exact failure this sink
// guards against) must not be able to stall coordinator shutdown. Each worker
// finishes the group it already holds, then writes whatever is buffered at
// that instant (best-effort, on the worker goroutine) and returns. Ops
// submitted after that final drain stay buffered and are never written; in
// practice the process exits shortly after close.
func (t *telemetrySink) close() {
	if t == nil {
		return
	}
	t.closeOnce.Do(func() {
		close(t.done)
	})
}

// closeAndWait closes the sink and waits up to timeout for every worker to
// finish its final drain. It reports whether the workers exited in time. It
// exists so tests (and any future graceful-shutdown caller) can observe the
// flush; the production Server.Close path uses close and does not wait.
func (t *telemetrySink) closeAndWait(timeout time.Duration) bool {
	if t == nil {
		return true
	}
	t.close()
	stopped := make(chan struct{})
	go func() {
		t.workers.Wait()
		close(stopped)
	}()
	select {
	case <-stopped:
		return true
	case <-time.After(timeout):
		return false
	}
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
