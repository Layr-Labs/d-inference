// Request queue management for the Darkbloom coordinator.
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
	"context"
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
	Pending    *PendingRequest
	ResponseCh chan *Provider // receives the assigned provider
	EnqueuedAt time.Time
	DoneCh     chan struct{} // closed when the waiter is no longer interested
	doneOnce   sync.Once

	// Decision captures the cost breakdown of the routing decision that
	// dispatched this queued request. Populated by drainQueuedRequestsForModels
	// just before ResponseCh is signaled, so consumers can emit the same
	// metrics they would for an immediate (non-queued) selection.
	Decision RoutingDecision
}

func (r *QueuedRequest) init() {
	if r.ResponseCh == nil {
		r.ResponseCh = make(chan *Provider, 1)
	}
	if r.DoneCh == nil {
		r.DoneCh = make(chan struct{})
	}
}

func (r *QueuedRequest) markDone() {
	r.doneOnce.Do(func() {
		r.init()
		close(r.DoneCh)
	})
}

func (r *QueuedRequest) Done() <-chan struct{} {
	r.init()
	return r.DoneCh
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
	req.init()

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

// WaitForProviderContext blocks until a provider is assigned, the timeout
// expires, or the context is cancelled.
func (q *RequestQueue) WaitForProviderContext(ctx context.Context, req *QueuedRequest) (*Provider, error) {
	req.init()
	timer := time.NewTimer(q.maxWait)
	defer timer.Stop()

	select {
	case p := <-req.ResponseCh:
		req.markDone()
		if p == nil {
			return nil, ErrQueueTimeout
		}
		return p, nil
	case <-timer.C:
		// Remove the request from the queue
		req.markDone()
		q.Remove(req.RequestID, req.Model)
		return nil, ErrQueueTimeout
	case <-ctx.Done():
		req.markDone()
		q.Remove(req.RequestID, req.Model)
		return nil, ctx.Err()
	}
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

// PopNextFresh removes and returns the first non-stale request for a model.
func (q *RequestQueue) PopNextFresh(model string) *QueuedRequest {
	q.mu.Lock()
	defer q.mu.Unlock()

	queue := q.queues[model]
	if len(queue) == 0 {
		return nil
	}

	now := time.Now()
	for len(queue) > 0 {
		req := queue[0]
		queue = queue[1:]
		q.queues[model] = queue
		if now.Sub(req.EnqueuedAt) > q.maxWait {
			req.markDone()
			select {
			case req.ResponseCh <- nil:
			default:
			}
			continue
		}
		return req
	}

	return nil
}

// RequeueFront pushes a request back to the front of its model queue.
func (q *RequestQueue) RequeueFront(req *QueuedRequest) {
	req.init()

	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[req.Model]
	queue = append([]*QueuedRequest{req}, queue...)
	q.queues[req.Model] = queue
}

// MaxSize returns the per-model maximum queue depth.
func (q *RequestQueue) MaxSize() int {
	return q.maxSize
}

// QueueSize returns the number of queued requests for a model.
func (q *RequestQueue) QueueSize(model string) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[model])
}

func (q *RequestQueue) QueueStats(model string) (depth int, oldestAge time.Duration) {
	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[model]
	depth = len(queue)
	if depth == 0 {
		return 0, 0
	}
	now := time.Now()
	oldest := queue[0].EnqueuedAt
	for _, req := range queue[1:] {
		if req.EnqueuedAt.Before(oldest) {
			oldest = req.EnqueuedAt
		}
	}
	if !oldest.IsZero() {
		oldestAge = now.Sub(oldest)
	}
	return depth, oldestAge
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

// PreferWaiterOwners returns the distinct owner account IDs of PreferOwner
// waiters currently queued for a model. Used by RejectUnservableQueuedRequests
// to compute owner eligibility OUTSIDE the queue lock (OwnedProviderSummary
// takes the registry lock), avoiding any q.mu→r.mu nesting.
func (q *RequestQueue) PreferWaiterOwners(model string) []string {
	q.mu.Lock()
	defer q.mu.Unlock()
	seen := make(map[string]struct{})
	var owners []string
	for _, req := range q.queues[model] {
		if req.Pending != nil && req.Pending.PreferOwner && req.Pending.OwnerAccountID != "" {
			if _, ok := seen[req.Pending.OwnerAccountID]; !ok {
				seen[req.Pending.OwnerAccountID] = struct{}{}
				owners = append(owners, req.Pending.OwnerAccountID)
			}
		}
	}
	return owners
}

// FailQueuedRequestsForModel rejects queued requests for a model by sending nil
// on their ResponseCh. Waiters receive ErrQueueTimeout. Called when the
// coordinator determines no provider can serve the model (e.g. all load_model
// attempts failed with no alternative provider).
//
// Owner-scoped waiters are preserved because this verdict comes from a PUBLIC
// capacity check, which ignores the caller's own machine:
//   - Exclusive self-route (Pending.SelfRouteOnly) is ALWAYS preserved — it only
//     queues after the preflight confirmed the owner has an online machine, so
//     its own (busy) machine may free up; it never falls back to public.
//   - Prefer (Pending.PreferOwner) is preserved ONLY when preferOwnerEligible
//     says the owner currently has an owned provider serving the model (it may
//     free up). A prefer waiter with NO owned provider is effectively a public
//     request, so it is failed fast like any other public waiter rather than
//     left to hit the 120s stale timeout.
//
// Preserved waiters drain on availability or time out naturally via CleanStale
// (surfacing machine_busy). Returns the number of requests failed.
func (q *RequestQueue) FailQueuedRequestsForModel(model string, preferOwnerEligible map[string]bool) int {
	q.mu.Lock()
	defer q.mu.Unlock()

	queue := q.queues[model]
	failed := 0
	var survivors []*QueuedRequest
	for _, req := range queue {
		if p := req.Pending; p != nil {
			if p.SelfRouteOnly {
				survivors = append(survivors, req)
				continue
			}
			if p.PreferOwner && preferOwnerEligible[p.OwnerAccountID] {
				survivors = append(survivors, req)
				continue
			}
		}
		req.markDone()
		select {
		case req.ResponseCh <- nil:
			failed++
		default:
		}
	}
	if len(survivors) == 0 {
		delete(q.queues, model)
	} else {
		q.queues[model] = survivors
	}
	return failed
}

// QueuedModels returns the set of model IDs that currently have at least
// one request waiting in the queue.
func (q *RequestQueue) QueuedModels() []string {
	q.mu.Lock()
	defer q.mu.Unlock()

	var models []string
	for model := range q.queues {
		q.cleanStaleLocked(model)
		if len(q.queues[model]) > 0 {
			models = append(models, model)
		}
	}
	return models
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
			req.markDone()
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
