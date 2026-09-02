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
// enqueues an op (which never blocks), ONE long-lived worker drains the queue,
// and when the buffer is full the write is DROPPED and counted. Goroutines and
// memory are therefore bounded by construction, and inference latency is fully
// decoupled from store latency.
//
// Ops are TYPED so the worker can coalesce them: it gathers up to maxBatch ops
// (waiting at most window for more), writes every route record in the group
// with ONE multi-row store call and every run of outcome updates with ONE
// pipelined call, and runs generic closures (rejections) inline at their queue
// position. See telemetry_sink_batch.go for the ordering argument.
//
// Shutdown: close marks the sink closed (later submits are rejected and
// counted as drops) and signals the worker, which finishes its group, writes
// whatever was buffered at that instant, and exits. closeAndWait bounds how
// long a caller waits for that final drain; Server.Close uses it so the rows
// are flushed before the process closes the database pool.

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Sink defaults. The buffer absorbs brief store stalls without dropping, while
// the single worker preserves route insert -> outcome update ordering for a
// given request without adding request latency: callers still only enqueue
// work into the bounded channel. Telemetry is best-effort and must not compete
// with inference for resources.
//
// maxBatch/window bound one worker group: at most 256 ops per group, and a
// group is flushed no later than 100ms after its first op even when the queue
// is quiet. 256 records × 57 columns stays well inside one INSERT statement.
const (
	defaultTelemetrySinkCapacity    = 4096
	defaultTelemetrySinkWorkers     = 1
	defaultTelemetrySinkMaxBatch    = 256
	defaultTelemetrySinkBatchWindow = 100 * time.Millisecond

	// telemetrySinkShutdownFlush bounds how long Server.Close waits for the
	// sink's final drain. main defers the store's Close before Server.Close,
	// so this flush runs while the pool is still open; a stuck store cannot
	// hold shutdown past the deadline.
	telemetrySinkShutdownFlush = 2 * time.Second
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
// persistence. submit* enqueue without blocking; the worker drains the queue
// in coalesced groups, running each store call inside a panic-safe wrapper.
// When the buffer is full the write is dropped and counted, so the inference
// path can never be slowed or blocked by telemetry — even if the store is slow
// or down — and goroutine/memory growth is bounded.
type telemetrySink struct {
	ch     chan telemetryOp
	done   chan struct{}
	logger *slog.Logger
	// dropped counts every op that was not persisted: rejected at the buffer
	// (full or closed) or dropped by the worker (unavailable store, closing).
	dropped atomic.Int64
	// closeOnce makes close idempotent: done is closed exactly once even when
	// close is reached from more than one shutdown path.
	closeOnce sync.Once
	// stateMu orders close against enqueue: enqueue holds the read lock while
	// it checks closed and offers the op; close takes the write lock to set
	// closed. Once close returns no further op can enter the buffer, so the
	// final drain is bounded by what was buffered at that instant.
	stateMu sync.RWMutex
	closed  bool

	// maxBatch caps the ops gathered into one worker group; window caps how
	// long the worker waits for more ops after the group's first one.
	maxBatch int
	window   time.Duration

	// store persists typed ops (records, updates). It is bound once by the
	// first typed submit (bind); the channel send/receive orders that write
	// before any worker read, so no lock is needed on the read side.
	store    store.TelemetryStore
	bindOnce sync.Once

	// workers counts live worker goroutines so closeAndWait can observe the
	// final drain. workerCount is what the constructor actually started
	// (always 1: the ordering guarantee depends on a single consumer).
	workers     sync.WaitGroup
	workerCount int
}

// newTelemetrySink starts the worker with the default batching parameters.
// capacity falls back to the package default when non-positive; workers is
// clamped to 1 (see newBatchingTelemetrySink).
func newTelemetrySink(logger *slog.Logger, capacity, workers int) *telemetrySink {
	return newBatchingTelemetrySink(logger, capacity, workers, defaultTelemetrySinkMaxBatch, defaultTelemetrySinkBatchWindow)
}

// newBatchingTelemetrySink is newTelemetrySink with explicit group bounds.
// maxBatch 1 disables coalescing (every op is its own group, no window wait).
// Non-positive values fall back to the package defaults.
//
// The sink runs exactly ONE worker: the per-request insert -> update ordering
// (telemetry_sink_batch.go) holds only with a single FIFO consumer. A request
// for more workers is clamped and logged rather than honoured.
func newBatchingTelemetrySink(logger *slog.Logger, capacity, workers, maxBatch int, window time.Duration) *telemetrySink {
	if capacity <= 0 {
		capacity = defaultTelemetrySinkCapacity
	}
	if workers <= 0 {
		workers = defaultTelemetrySinkWorkers
	}
	if workers != 1 {
		if logger != nil {
			logger.Warn("routing telemetry sink runs exactly one worker (per-request ordering); clamping",
				"requested_workers", workers,
			)
		}
		workers = 1
	}
	if maxBatch <= 0 {
		maxBatch = defaultTelemetrySinkMaxBatch
	}
	if window <= 0 {
		window = defaultTelemetrySinkBatchWindow
	}
	t := &telemetrySink{
		ch:          make(chan telemetryOp, capacity),
		done:        make(chan struct{}),
		logger:      logger,
		maxBatch:    maxBatch,
		window:      window,
		workerCount: workers,
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
// when the work was accepted, or false when it was dropped and counted — the
// buffer was full, or the sink is closed. The inference request path calls
// this, so it must never block.
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
// and count (full buffer, or closed sink). The read lock is held only across
// the closed check and a non-blocking send, so it never waits on the store.
func (t *telemetrySink) enqueue(op telemetryOp) bool {
	t.stateMu.RLock()
	defer t.stateMu.RUnlock()
	if t.closed {
		t.countDrops(1)
		return false
	}
	select {
	case t.ch <- op:
		return true
	default:
		t.countDrops(1)
		return false
	}
}

// close marks the sink closed and signals the worker; it is idempotent and
// never blocks on in-flight telemetry writes: a stuck store call (the exact
// failure this sink guards against) must not be able to stall coordinator
// shutdown. After close returns no new op can be accepted; the worker
// finishes the group it holds, writes what was buffered, and exits.
func (t *telemetrySink) close() {
	if t == nil {
		return
	}
	t.closeOnce.Do(func() {
		t.stateMu.Lock()
		t.closed = true
		close(t.done)
		t.stateMu.Unlock()
	})
}

// closeAndWait closes the sink and waits up to timeout for the worker to
// finish its final drain, reporting whether it did. Server.Close uses it so
// buffered route rows reach the store before the process closes the pool;
// tests use it to observe the flush. Because close rejects further submits,
// the drain cannot be prolonged by refills.
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

// isClosed reports whether close has been called (the worker is draining).
func (t *telemetrySink) isClosed() bool {
	select {
	case <-t.done:
		return true
	default:
		return false
	}
}

// countDrops adds n unpersisted ops to the drop counter and emits the
// throttled warning when the cumulative count crosses a power of ten.
func (t *telemetrySink) countDrops(n int) {
	if n <= 0 {
		return
	}
	after := t.dropped.Add(int64(n))
	t.maybeLogDrop(after-int64(n), after)
}

// maybeLogDrop emits a throttled warning so operators notice sustained drops
// without flooding logs: it logs only when the cumulative drop count crosses a
// power of ten (1, 10, 100, 1000, …) between before and after.
func (t *telemetrySink) maybeLogDrop(before, after int64) {
	if t.logger == nil || !crossesPowerOfTen(before, after) {
		return
	}
	t.logger.Warn("routing telemetry sink dropping writes — inference is unaffected",
		"dropped_total", after,
		"capacity", cap(t.ch),
	)
}

// crossesPowerOfTen reports whether some power of ten p (1, 10, 100, …)
// satisfies before < p <= after. It is the throttle key for drop logging and
// works for multi-op drops, where a single increment could skip a threshold.
func crossesPowerOfTen(before, after int64) bool {
	for p := int64(1); p <= after; p *= 10 {
		if p > before {
			return true
		}
	}
	return false
}
