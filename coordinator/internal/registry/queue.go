// Request queue management for the DGInf coordinator.
//
// When all providers serving a model are busy, instead of immediately
// returning 503, the coordinator enqueues the request and waits for a
// provider to become available. When a provider finishes a job and calls
// SetProviderIdle, the queue is checked and the first matching queued
// request is assigned to that provider.
//
// Queue limits:
//   - maxSize: maximum number of queued requests per model (default 10)
//   - maxWait: maximum time a request can wait in the queue (default 30s)
//
// Stale requests (those past maxWait) are cleaned up both lazily (on
// enqueue) and can be cleaned up explicitly via CleanStale.
package registry

import (
	"encoding/json"
	"errors"
	"sync"
	"time"
)

// ErrQueueFull is returned when the queue for a model has reached maxSize.
var ErrQueueFull = errors.New("request queue is full")

// ErrQueueTimeout is returned when a queued request times out waiting for a provider.
var ErrQueueTimeout = errors.New("request queue timeout")

// QueuedRequest represents a request waiting for a provider.
type QueuedRequest struct {
	RequestID  string
	Model      string
	Body       json.RawMessage
	ResponseCh chan *Provider // receives the assigned provider
	EnqueuedAt time.Time
}

// RequestQueue manages per-model queues for requests awaiting providers.
type RequestQueue struct {
	mu      sync.Mutex
	queues  map[string][]*QueuedRequest // model -> queue
	maxSize int                         // max queue size per model
	maxWait time.Duration               // max time a request waits
}

// NewRequestQueue creates a new RequestQueue with the given limits.
func NewRequestQueue(maxSize int, maxWait time.Duration) *RequestQueue {
	return &RequestQueue{
		queues:  make(map[string][]*QueuedRequest),
		maxSize: maxSize,
		maxWait: maxWait,
	}
}

// Enqueue adds a request to the queue for the given model.
// Returns ErrQueueFull if the queue for this model is at capacity.
func (q *RequestQueue) Enqueue(req *QueuedRequest) error {
	q.mu.Lock()
	defer q.mu.Unlock()

	// Clean stale entries first
	q.cleanStaleLocked(req.Model)

	queue := q.queues[req.Model]
	if len(queue) >= q.maxSize {
		return ErrQueueFull
	}

	req.EnqueuedAt = time.Now()
	q.queues[req.Model] = append(queue, req)
	return nil
}

// WaitForProvider blocks until a provider is assigned or the timeout expires.
// The caller should call Enqueue first, then WaitForProvider.
func (q *RequestQueue) WaitForProvider(req *QueuedRequest) (*Provider, error) {
	select {
	case p := <-req.ResponseCh:
		if p == nil {
			return nil, ErrQueueTimeout
		}
		return p, nil
	case <-time.After(q.maxWait):
		// Remove the request from the queue
		q.Remove(req.RequestID, req.Model)
		return nil, ErrQueueTimeout
	}
}

// TryAssign attempts to assign a provider to the first queued request for
// the given model. Returns true if a request was assigned. The provider's
// status is set to StatusServing if assigned.
func (q *RequestQueue) TryAssign(model string, provider *Provider) bool {
	q.mu.Lock()
	defer q.mu.Unlock()

	queue := q.queues[model]
	if len(queue) == 0 {
		return false
	}

	now := time.Now()

	// Find the first non-stale request
	for len(queue) > 0 {
		req := queue[0]
		queue = queue[1:]
		q.queues[model] = queue

		// Skip stale requests
		if now.Sub(req.EnqueuedAt) > q.maxWait {
			close(req.ResponseCh)
			continue
		}

		// Assign the provider
		provider.Status = StatusServing
		select {
		case req.ResponseCh <- provider:
			return true
		default:
			// Consumer already timed out / gone
			continue
		}
	}

	return false
}

// Remove removes a specific request from the queue by request ID.
func (q *RequestQueue) Remove(requestID, model string) {
	q.mu.Lock()
	defer q.mu.Unlock()

	queue := q.queues[model]
	for i, req := range queue {
		if req.RequestID == requestID {
			q.queues[model] = append(queue[:i], queue[i+1:]...)
			return
		}
	}
}

// QueueSize returns the number of queued requests for a model.
func (q *RequestQueue) QueueSize(model string) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[model])
}

// TotalSize returns the total number of queued requests across all models.
func (q *RequestQueue) TotalSize() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	total := 0
	for _, queue := range q.queues {
		total += len(queue)
	}
	return total
}

// CleanStale removes requests that have exceeded maxWait from all queues.
func (q *RequestQueue) CleanStale() {
	q.mu.Lock()
	defer q.mu.Unlock()

	for model := range q.queues {
		q.cleanStaleLocked(model)
	}
}

// cleanStaleLocked removes stale requests for a specific model.
// Caller must hold q.mu.
func (q *RequestQueue) cleanStaleLocked(model string) {
	queue := q.queues[model]
	if len(queue) == 0 {
		return
	}

	now := time.Now()
	var fresh []*QueuedRequest
	for _, req := range queue {
		if now.Sub(req.EnqueuedAt) > q.maxWait {
			// Close the response channel to signal timeout
			select {
			case req.ResponseCh <- nil:
			default:
			}
		} else {
			fresh = append(fresh, req)
		}
	}
	q.queues[model] = fresh
}
