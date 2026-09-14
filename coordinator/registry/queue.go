package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/registry/requestqueue"
)

// ErrQueueFull is returned when the queue for a model has reached maxSize.
var ErrQueueFull = requestqueue.ErrFull

// RequestQueue keeps the registry's typed queue API. The requestqueue owner
// holds its FIFO and lock; registry adds provider constraints and wait handling.
type RequestQueue struct {
	queue requestqueue.Queue[*QueuedRequest]
}

// Default queue limits (see NewRequestQueueFromEnv for the sizing rationale).
const (
	defaultQueueMaxDepth = 32
	defaultQueueMaxWait  = 120 * time.Second
)

// NewRequestQueue creates a queue with the given per-model depth and wait limit.
func NewRequestQueue(maxSize int, maxWait time.Duration) *RequestQueue {
	return &RequestQueue{queue: requestqueue.New[*QueuedRequest](maxSize, maxWait)}
}

// NewRequestQueueFromEnv creates a RequestQueue sized from the environment:
//
//   - EIGENINFERENCE_QUEUE_MAX_DEPTH — per-model depth, default 32. The queue
//     drains fleet-wide (every SetProviderIdle / heartbeat sweeps it), so with a
//     pool of hundreds of boxes and a few-second service time the fleet turns
//     over hundreds of slots per second; a 32-deep queue clears in well under a
//     second of fleet throughput and adds negligible tail latency, while depth
//     10 rejected overflow bursts the fleet could absorb almost immediately.
//   - EIGENINFERENCE_QUEUE_MAX_WAIT — per-request wait bound, default 120s
//     (Go duration string, e.g. "45s").
//
// Non-positive or malformed values fall back to the defaults.
func NewRequestQueueFromEnv() *RequestQueue {
	depth := env.EnvInt(env.EnvPrefix+"_QUEUE_MAX_DEPTH", defaultQueueMaxDepth)
	if depth < 1 {
		depth = defaultQueueMaxDepth
	}
	wait := envDuration(env.EnvPrefix+"_QUEUE_MAX_WAIT", defaultQueueMaxWait)
	if wait <= 0 {
		wait = defaultQueueMaxWait
	}
	return NewRequestQueue(depth, wait)
}

func queuedRequestAccess() requestqueue.Access[*QueuedRequest] {
	return requestqueue.Access[*QueuedRequest]{
		Info: func(req *QueuedRequest) requestqueue.Info {
			return requestqueue.Info{ID: req.RequestID, Model: req.Model, EnqueuedAt: req.EnqueuedAt}
		},
		Prepare: (*QueuedRequest).init,
		Enqueued: func(req *QueuedRequest, at time.Time, depth int) {
			req.EnqueuedAt = at
			req.EnqueuePosition = depth
			req.DepthAtEnqueue = depth
		},
		Expire: (*QueuedRequest).expireFromQueue,
	}
}

func (q *RequestQueue) Enqueue(req *QueuedRequest) error {
	err := q.queue.Enqueue(req, queuedRequestAccess())
	if err == requestqueue.ErrFull {
		return ErrQueueFull
	}
	return err
}

func (q *RequestQueue) Remove(requestID, model string) {
	q.queue.Remove(requestID, model, queuedRequestAccess())
}

func (q *RequestQueue) PopNextFresh(model string) *QueuedRequest {
	return q.queue.PopNextFresh(model, queuedRequestAccess())
}

func (q *RequestQueue) RequeueFront(req *QueuedRequest) {
	q.queue.RequeueFront(req, queuedRequestAccess())
}

func (q *RequestQueue) MaxSize() int { return q.queue.MaxSize() }

func (q *RequestQueue) QueueSize(model string) int { return q.queue.QueueSize(model) }

func (q *RequestQueue) QueueStats(model string) (depth int, oldestAge time.Duration) {
	return q.queue.QueueStats(model, queuedRequestAccess())
}

func (q *RequestQueue) QueueDepths() (total int, byModel map[string]int) {
	return q.queue.QueueDepths()
}

func (q *RequestQueue) TotalSize() int { return q.queue.TotalSize() }

func (q *RequestQueue) HasQueued() bool { return q.queue.HasQueued() }

func (q *RequestQueue) QueuedModels() []string { return q.queue.QueuedModels(queuedRequestAccess()) }
