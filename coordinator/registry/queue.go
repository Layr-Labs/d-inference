// Request queue management for the Darkbloom coordinator.
//
// When all providers serving a model are busy, instead of immediately
// returning 503, the coordinator enqueues the request and waits for a
// provider to become available. When a provider finishes a job and calls
// SetProviderIdle, the queue is checked and the first matching queued
// request is assigned to that provider.
//
// Queue limits:
//   - maxSize: maximum number of queued requests per model (default 32,
//     EIGENINFERENCE_QUEUE_MAX_DEPTH)
//   - maxWait: maximum time a request can wait in the queue (default 120s,
//     EIGENINFERENCE_QUEUE_MAX_WAIT)
//
// Stale requests (those past maxWait) are cleaned up lazily: Enqueue and
// QueuedModels sweep a model's queue via cleanStaleLocked, PopNextFresh
// rejects stale entries as it pops, and each waiter enforces its own maxWait
// timer in WaitForProviderContext.
package registry

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// ErrQueueFull is returned when the queue for a model has reached maxSize.
var ErrQueueFull = errors.New("request queue is full")

// ErrQueueTimeout is returned when a queued request times out waiting for a provider.
var ErrQueueTimeout = errors.New("request queue timeout")

// ErrQueueTTFTTooSlow is returned when the queue drain determines the waiter is
// deterministically unservable: every provider that could otherwise serve the
// model fails ONLY the per-request TTFT ceiling (pr.MaxTTFTMs, hard-reject
// mode). Waiting out maxWait cannot change that verdict within the pass, so the
// waiter is failed immediately and the API layer writes the standard
// ttft_too_slow 429 instead of a queue timeout.
var ErrQueueTTFTTooSlow = errors.New("all providers for queued request exceed the TTFT target")

// ErrModelShed is returned when an operator reject-set replacement removes a
// queued public request, or when a request that passed the API admission check
// races with that replacement and attempts to enqueue or drain afterward.
var ErrModelShed = errors.New("request model is temporarily shed")

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
	// queueState is guarded by RequestQueue.mu. It linearizes provider
	// assignment and terminal failure against timeout/cancellation.
	queueState queuedRequestState

	// Decision captures the cost breakdown of the routing decision that
	// dispatched (or terminally failed) this queued request. Populated by
	// drainQueuedRequestsForModels just before ResponseCh is signaled, so
	// consumers can emit the same metrics they would for an immediate
	// (non-queued) selection — and, on a TTFT failure, compute Retry-After
	// from BestTTFTMs.
	Decision RoutingDecision

	// FailureReason, when non-nil, is the terminal cause recorded before
	// ResponseCh was signaled with nil. WaitForProviderContext returns it in
	// place of ErrQueueTimeout so the API waiter can write the precise
	// rejection (e.g. the ttft_too_slow 429). Written before the ResponseCh
	// send and read only after receiving nil, so the channel orders the
	// accesses.
	FailureReason error
}

type queuedRequestState uint8

const (
	queuedRequestWaiting queuedRequestState = iota
	queuedRequestAssigned
	queuedRequestFailed
	queuedRequestAbandoned
)

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

// failWithReason terminally rejects the waiter with a specific cause. If the
// waiter already gave up (timeout/cancel), the buffered nil send is a no-op and
// the reason is never read.
func (r *QueuedRequest) failWithReason(reason error) {
	r.init()
	r.FailureReason = reason
	r.markDone()
	select {
	case r.ResponseCh <- nil:
	default:
	}
}

// drainRejectionTTFTTerminal reports whether a drain-time reservation failure
// is a PURE TTFT rejection — deterministic for this pass, so the waiter should
// be failed with ErrQueueTTFTTooSlow instead of hanging until maxWait:
//   - at least one provider was rejected only by the per-request TTFT ceiling
//     (TTFTRejections > 0 requires pr.MaxTTFTMs > 0, i.e. hard-reject mode);
//   - no provider was capacity-rejected: a busy fast provider freeing up could
//     still serve the request, so mixed rejections keep waiting;
//   - no candidate passed the scan: CandidateCount > 0 with a nil provider is
//     the transient admit re-check race, not unservability.
//
// Owner-scoped waiters are never TTFT-failed on the public-fleet verdict
// (mirrors FailQueuedRequestsForModel's preservation semantics). Their queue
// ceiling is already 0 (queueMaxTTFTMs), so they cannot produce TTFT
// rejections; the explicit guard keeps the invariant even if that wiring
// changes.
func drainRejectionTTFTTerminal(pr *PendingRequest, decision RoutingDecision) bool {
	if pr == nil || pr.SelfRouteOnly || pr.PreferOwner {
		return false
	}
	return decision.TTFTRejections > 0 &&
		decision.CapacityRejections == 0 &&
		decision.CandidateCount == 0
}

// RequestQueue manages per-model queues for requests awaiting providers.
type RequestQueue struct {
	mu         sync.Mutex
	queues     map[string][]*QueuedRequest // model -> queue
	shedModels map[string]struct{}         // current public reject-set snapshot
	maxSize    int                         // max queue size per model
	maxWait    time.Duration               // max time a request waits
}

// Default queue limits (see NewRequestQueueFromEnv for the sizing rationale).
const (
	defaultQueueMaxDepth = 32
	defaultQueueMaxWait  = 120 * time.Second
)

// NewRequestQueue creates a new RequestQueue with the given limits.
func NewRequestQueue(maxSize int, maxWait time.Duration) *RequestQueue {
	return &RequestQueue{
		queues:  make(map[string][]*QueuedRequest),
		maxSize: maxSize,
		maxWait: maxWait,
	}
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

// Enqueue adds a request to the queue for the given model.
// Returns ErrQueueFull if the queue for this model is at capacity.
func (q *RequestQueue) Enqueue(req *QueuedRequest) error {
	req.init()

	q.mu.Lock()
	defer q.mu.Unlock()
	if queuedRequestMatchesModels(req, q.shedModels) {
		return ErrModelShed
	}

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
		return queuedRequestResult(req, p)
	case <-timer.C:
		if q.abandonIfWaiting(req) {
			return nil, ErrQueueTimeout
		}
		return queuedRequestResult(req, <-req.ResponseCh)
	case <-ctx.Done():
		if q.abandonIfWaiting(req) {
			return nil, ctx.Err()
		}
		return queuedRequestResult(req, <-req.ResponseCh)
	}
}

func queuedRequestResult(req *QueuedRequest, provider *Provider) (*Provider, error) {
	req.markDone()
	if provider != nil {
		return provider, nil
	}
	if req.FailureReason != nil {
		return nil, req.FailureReason
	}
	return nil, ErrQueueTimeout
}

// abandonIfWaiting atomically commits timeout/cancellation against provider
// assignment and queue failures. False means another terminal outcome already
// committed and its buffered response must be consumed by the waiter.
func (q *RequestQueue) abandonIfWaiting(req *QueuedRequest) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if req == nil || req.queueState != queuedRequestWaiting {
		return false
	}
	req.queueState = queuedRequestAbandoned
	req.markDone()
	q.removeLocked(req.RequestID, req.Model)
	return true
}

// Remove removes a specific request from the queue by request ID.
func (q *RequestQueue) Remove(requestID, model string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.removeLocked(requestID, model)
}

func (q *RequestQueue) removeLocked(requestID, model string) {
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
		if len(queue) == 0 {
			delete(q.queues, model)
		}
		if now.Sub(req.EnqueuedAt) > q.maxWait {
			q.failRequestLocked(req, nil)
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
	if req.queueState != queuedRequestWaiting {
		return
	}
	if queuedRequestMatchesModels(req, q.shedModels) {
		q.failRequestLocked(req, ErrModelShed)
		return
	}
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
// Preserved waiters drain on availability or hit their own maxWait timer in
// WaitForProviderContext (surfacing machine_busy); entries they leave behind
// are swept lazily by cleanStaleLocked on the next Enqueue or QueuedModels
// scan. Returns the number of requests failed.
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
		if q.failRequestLocked(req, nil) {
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

// ReplaceShedModels atomically installs the queue's public reject-set snapshot
// and rejects matching waiters already present. Enqueue, requeue, and drain
// assignment consult the same snapshot under q.mu, closing races where a
// request passed API admission just before an operator PUT. Requests queue under
// the resolved build, so matching checks both that id and Pending.PublicModel.
// Exclusive self-route bypasses the public shed policy. Returns the number of
// queued waiters removed.
func (q *RequestQueue) ReplaceShedModels(models []string) int {
	shed := make(map[string]struct{}, len(models))
	for _, model := range models {
		if model != "" {
			shed[model] = struct{}{}
		}
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.shedModels = shed

	failed := 0
	for queueModel := range q.queues {
		q.cleanStaleLocked(queueModel)
		queue := q.queues[queueModel]
		if len(queue) == 0 {
			continue
		}
		survivors := make([]*QueuedRequest, 0, len(queue))
		for _, req := range queue {
			if !queuedRequestMatchesModels(req, shed) {
				survivors = append(survivors, req)
				continue
			}
			if q.failRequestLocked(req, ErrModelShed) {
				failed++
			}
		}
		if len(survivors) == 0 {
			delete(q.queues, queueModel)
		} else {
			q.queues[queueModel] = survivors
		}
	}
	return failed
}

// AssignProviderIfAllowed is the queue-drain commit point. It serializes the
// final shed check with ReplaceShedModels and the provider send, so either the
// assignment commits before an operator replacement or the waiter receives
// ErrModelShed after it; a popped request cannot slip through between them.
func (q *RequestQueue) AssignProviderIfAllowed(req *QueuedRequest, provider *Provider) bool {
	if req == nil || provider == nil {
		return false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if req.queueState != queuedRequestWaiting {
		return false
	}
	if queuedRequestMatchesModels(req, q.shedModels) {
		q.failRequestLocked(req, ErrModelShed)
		return false
	}
	select {
	case req.ResponseCh <- provider:
		req.queueState = queuedRequestAssigned
		return true
	default:
		return false
	}
}

// FailRequest commits a typed terminal queue failure unless assignment,
// timeout, or cancellation already won the request-state transition.
func (q *RequestQueue) FailRequest(req *QueuedRequest, reason error) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.failRequestLocked(req, reason)
}

func (q *RequestQueue) failRequestLocked(req *QueuedRequest, reason error) bool {
	if req == nil || req.queueState != queuedRequestWaiting {
		return false
	}
	req.queueState = queuedRequestFailed
	req.failWithReason(reason)
	return true
}

func queuedRequestMatchesModels(req *QueuedRequest, models map[string]struct{}) bool {
	if req == nil || len(models) == 0 {
		return false
	}
	if req.Pending != nil && req.Pending.SelfRouteOnly {
		return false
	}
	if _, ok := models[req.Model]; ok {
		return true
	}
	if req.Pending != nil {
		_, ok := models[req.Pending.PublicModel]
		return ok
	}
	return false
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
			q.failRequestLocked(req, nil)
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
