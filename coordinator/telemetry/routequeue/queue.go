package routequeue

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
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
	DefaultCapacity    = 4096
	defaultWorkers     = 1
	DefaultMaxBatch    = 256
	DefaultBatchWindow = 100 * time.Millisecond

	// ShutdownFlush bounds how long Server.Close waits for the
	// sink's final drain. main defers the store's Close before Server.Close,
	// so this flush runs while the pool is still open; a stuck store cannot
	// hold shutdown past the deadline.
	ShutdownFlush = 2 * time.Second
)

// operation is one queued unit of telemetry work. Exactly one of fn, record,
// or update is set.
type operation struct {
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

// Sink is a bounded, non-blocking work queue for best-effort telemetry
// persistence. Submit* enqueue without blocking; the worker drains the queue
// in coalesced groups, running each store call inside a panic-safe wrapper.
// When the buffer is full the write is dropped and counted, so the inference
// path can never be slowed or blocked by telemetry — even if the store is slow
// or down — and goroutine/memory growth is bounded.
type Sink struct {
	ch     chan operation
	done   chan struct{}
	logger *slog.Logger
	// dropped counts every op that was not persisted: rejected at the buffer
	// (full or closed) or dropped by the worker (unavailable store, closing).
	dropped atomic.Int64
	// closeOnce makes Close idempotent: done is closed exactly once even when
	// Close is reached from more than one shutdown path.
	closeOnce sync.Once
	// stateMu orders Close against enqueue: enqueue holds the read lock while
	// it checks closed and offers the op; Close takes the write lock to set
	// closed. Once Close returns no further op can enter the buffer, so the
	// final drain is bounded by what was buffered at that instant.
	stateMu sync.RWMutex
	closed  bool

	// maxBatch caps the ops gathered into one worker group; window caps how
	// long the worker waits for more ops after the group's first one.
	maxBatch int
	window   time.Duration

	// store persists typed ops (records, updates). It is bound once by the
	// first typed Submit (Bind); the channel send/receive orders that write
	// before any worker read, so no lock is needed on the read side.
	store    store.TelemetryStore
	bindOnce sync.Once

	// workers counts live worker goroutines so CloseAndWait can observe the
	// final drain. workerCount is what the constructor actually started
	// (always 1: the ordering guarantee depends on a single consumer).
	workers     sync.WaitGroup
	workerCount int
}

// New starts the worker with the default batching parameters.
// capacity falls back to the package default when non-positive; workers is
// clamped to 1 (see NewBatching).
func New(logger *slog.Logger, capacity, workers int) *Sink {
	return NewBatching(logger, capacity, workers, DefaultMaxBatch, DefaultBatchWindow)
}

// NewBatching is New with explicit group bounds.
// maxBatch 1 disables coalescing (every op is its own group, no window wait).
// Non-positive values fall back to the package defaults.
//
// The sink runs exactly ONE worker: the per-request insert -> update ordering
// (batch.go) holds only with a single FIFO consumer. A request
// for more workers is clamped and logged rather than honoured.
func NewBatching(logger *slog.Logger, capacity, workers, maxBatch int, window time.Duration) *Sink {
	if capacity <= 0 {
		capacity = DefaultCapacity
	}
	if workers <= 0 {
		workers = defaultWorkers
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
		maxBatch = DefaultMaxBatch
	}
	if window <= 0 {
		window = DefaultBatchWindow
	}
	t := &Sink{
		ch:          make(chan operation, capacity),
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

// Bind sets the store that persists typed ops. The first call wins; later
// calls are no-ops. Callers must Bind before their first typed Submit (the
// Server helpers in api/route_telemetry_submit.go do this on every Submit, which
// is a cheap sync.Once check after the first).
func (t *Sink) Bind(st store.TelemetryStore) {
	if t == nil {
		return
	}
	t.bindOnce.Do(func() { t.store = st })
}

// Submit enqueues a generic closure without ever blocking. It returns true
// when the work was accepted, or false when it was dropped and counted — the
// buffer was full, or the sink is closed. The inference request path calls
// this, so it must never block.
func (t *Sink) Submit(fn func()) bool {
	if t == nil || fn == nil {
		return false
	}
	return t.enqueue(operation{fn: fn})
}

// SubmitRoute enqueues an inference_routes snapshot insert. Same non-blocking
// accept/drop contract as Submit.
func (t *Sink) SubmitRoute(record *store.InferenceRouteRecord) bool {
	if t == nil || record == nil {
		return false
	}
	return t.enqueue(operation{record: record})
}

// SubmitOutcome enqueues an outcome merge for (requestID, attempt). Same
// non-blocking accept/drop contract as Submit. The caller guarantees the
// matching SubmitRoute happened-before this call (dispatch precedes every
// commit/terminal), which is what lets the worker write records before
// updates inside one group.
func (t *Sink) SubmitOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) bool {
	if t == nil || outcome == nil {
		return false
	}
	return t.enqueue(operation{
		update: &store.InferenceRouteOutcomeUpdate{RequestID: requestID, Attempt: attempt, Outcome: outcome},
		model:  model,
	})
}

// enqueue is the single non-blocking entry into the buffer: accept, or drop
// and count (full buffer, or closed sink). The read lock is held only across
// the closed check and a non-blocking send, so it never waits on the store.
func (t *Sink) enqueue(op operation) bool {
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

// countDrops adds n unpersisted ops to the drop counter and emits the
// throttled warning when the cumulative count crosses a power of ten.
func (t *Sink) countDrops(n int) {
	if n <= 0 {
		return
	}
	after := t.dropped.Add(int64(n))
	t.maybeLogDrop(after-int64(n), after)
}

// maybeLogDrop emits a throttled warning so operators notice sustained drops
// without flooding logs: it logs only when the cumulative drop count crosses a
// power of ten (1, 10, 100, 1000, …) between before and after.
func (t *Sink) maybeLogDrop(before, after int64) {
	if t.logger == nil || !telemetry.CrossesPowerOfTen(before, after) {
		return
	}
	t.logger.Warn("routing telemetry sink dropping writes — inference is unaffected",
		"dropped_total", after,
		"capacity", cap(t.ch),
	)
}
