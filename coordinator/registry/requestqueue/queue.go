package requestqueue

import (
	"errors"
	"sync"
	"time"
)

var ErrFull = errors.New("request queue is full")

// Info is immutable queue metadata supplied by the request owner.
type Info struct {
	ID, Model  string
	EnqueuedAt time.Time
}

// Access projects an opaque request into queue metadata and lifecycle actions.
// Prepare runs before acquiring the queue lock. The remaining callbacks run
// under it, just as expiry and metadata updates did in the registry queue.
// They must not call back into this queue. Access carries no queue state.
type Access[T any] struct {
	Info     func(T) Info
	Prepare  func(T)
	Enqueued func(T, time.Time, int)
	Expire   func(T) bool
}

// Queue owns each model's FIFO, limits and mutex. Entry payloads remain with
// the caller; slices and the queue map never escape this owner.
type Queue[T any] struct {
	mu      sync.Mutex
	queues  map[string][]T
	maxSize int
	maxWait time.Duration
}

func New[T any](maxSize int, maxWait time.Duration) Queue[T] {
	return Queue[T]{queues: make(map[string][]T), maxSize: maxSize, maxWait: maxWait}
}

func (q *Queue[T]) MaxWait() time.Duration { return q.maxWait }

// Enqueue adds a request to the queue for the given model.
// Returns ErrFull if the queue for this model is at capacity.
func (q *Queue[T]) Enqueue(req T, access Access[T]) error {
	access.Prepare(req)

	q.mu.Lock()
	defer q.mu.Unlock()

	// Clean stale entries first
	q.cleanStaleLocked(access.Info(req).Model, access)

	queue := q.queues[access.Info(req).Model]
	if len(queue) >= q.maxSize {
		return ErrFull
	}

	access.Enqueued(req, time.Now(), len(queue))
	q.queues[access.Info(req).Model] = append(queue, req)
	return nil
}

// Remove removes a specific request from the queue by request ID.
func (q *Queue[T]) Remove(requestID, model string, access Access[T]) {
	q.mu.Lock()
	defer q.mu.Unlock()

	queue := q.queues[model]
	for i, req := range queue {
		if access.Info(req).ID == requestID {
			q.queues[model] = append(queue[:i], queue[i+1:]...)
			return
		}
	}
}

// PopNextFresh removes and returns the first non-stale request for a model.
func (q *Queue[T]) PopNextFresh(model string, access Access[T]) T {
	q.mu.Lock()
	defer q.mu.Unlock()

	queue := q.queues[model]
	if len(queue) == 0 {
		var empty T
		return empty
	}

	now := time.Now()
	for len(queue) > 0 {
		req := queue[0]
		queue = queue[1:]
		q.queues[model] = queue
		if len(queue) == 0 {
			delete(q.queues, model)
		}
		if now.Sub(access.Info(req).EnqueuedAt) > q.maxWait {
			access.Expire(req)
			continue
		}
		return req
	}

	var empty T
	return empty
}

// RequeueFront pushes a request back to the front of its model queue.
func (q *Queue[T]) RequeueFront(req T, access Access[T]) {
	access.Prepare(req)

	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[access.Info(req).Model]
	queue = append([]T{req}, queue...)
	q.queues[access.Info(req).Model] = queue
}

// MaxSize returns the per-model maximum queue depth.
func (q *Queue[T]) MaxSize() int {
	return q.maxSize
}

// QueueSize returns the number of queued requests for a model.
func (q *Queue[T]) QueueSize(model string) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[model])
}

func (q *Queue[T]) QueueStats(model string, access Access[T]) (depth int, oldestAge time.Duration) {
	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[model]
	depth = len(queue)
	if depth == 0 {
		return 0, 0
	}
	now := time.Now()
	oldest := access.Info(queue[0]).EnqueuedAt
	for _, req := range queue[1:] {
		if access.Info(req).EnqueuedAt.Before(oldest) {
			oldest = access.Info(req).EnqueuedAt
		}
	}
	if !oldest.IsZero() {
		oldestAge = now.Sub(oldest)
	}
	return depth, oldestAge
}

// QueueDepths returns the total number of queued requests and the per-model
// counts (nil when nothing is queued). READ-ONLY: unlike QueuedModels it does
// NOT sweep stale entries or signal any waiter, so an observability caller
// (the fleet sampler) can never change a client outcome. Stale-but-unswept
// waiters are counted — they still occupy the queue until a mutating path
// (Enqueue / QueuedModels / PopNextFresh / the waiter's own timer) removes them.
func (q *Queue[T]) QueueDepths() (total int, byModel map[string]int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for model, queue := range q.queues {
		if len(queue) == 0 {
			continue
		}
		if byModel == nil {
			byModel = make(map[string]int, len(q.queues))
		}
		byModel[model] = len(queue)
		total += len(queue)
	}
	return total, byModel
}

// TotalSize returns the total number of queued requests across all models.
func (q *Queue[T]) TotalSize() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	total := 0
	for _, queue := range q.queues {
		total += len(queue)
	}
	return total
}

// HasQueued reports whether any request is queued for any model. Cheaper than
// QueuedModels (no allocation, no stale sweep) for the per-heartbeat probe.
func (q *Queue[T]) HasQueued() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, queue := range q.queues {
		if len(queue) > 0 {
			return true
		}
	}
	return false
}

// QueuedModels returns the set of model IDs that currently have at least
// one request waiting in the queue.
func (q *Queue[T]) QueuedModels(access Access[T]) []string {
	q.mu.Lock()
	defer q.mu.Unlock()

	var models []string
	for model := range q.queues {
		q.cleanStaleLocked(model, access)
		if len(q.queues[model]) > 0 {
			models = append(models, model)
		}
	}
	return models
}

// cleanStaleLocked removes stale requests for a specific model.
// Caller must hold q.mu.
func (q *Queue[T]) cleanStaleLocked(model string, access Access[T]) {
	queue := q.queues[model]
	if len(queue) == 0 {
		return
	}

	now := time.Now()
	var fresh []T
	for _, req := range queue {
		if now.Sub(access.Info(req).EnqueuedAt) > q.maxWait {
			// Let the request owner signal timeout and release its assignment.
			access.Expire(req)
		} else {
			fresh = append(fresh, req)
		}
	}
	// Drop the key entirely when nothing survives so the per-model map tracks
	// live queues only (model ids are catalog-bounded, but no reason to retain
	// empty entries).
	if len(fresh) == 0 {
		delete(q.queues, model)
		return
	}
	q.queues[model] = fresh
}

// Visit inspects a model's entries in FIFO order under the queue lock without
// exposing the backing slice. The callback must not reenter this queue.
func (q *Queue[T]) Visit(model string, visit func(T)) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, req := range q.queues[model] {
		visit(req)
	}
}

// FailUnless expires every waiter except those preserved by caller policy.
// Policy and expiry execute under the same lock as the queue replacement.
func (q *Queue[T]) FailUnless(model string, preserve func(T) bool, expire func(T) bool) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	failed := 0
	var survivors []T
	for _, req := range q.queues[model] {
		if preserve(req) {
			survivors = append(survivors, req)
			continue
		}
		if expire(req) {
			failed++
		}
	}
	if len(survivors) == 0 {
		delete(q.queues, model)
	} else {
		q.queues[model] = survivors
	}
	return failed
}
