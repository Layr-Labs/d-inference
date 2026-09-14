package registry

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/requestqueue"
)

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
	// EnqueuePosition is the request's index in the model queue at enqueue
	// (0 = head; equals the queue length before the append) and
	// DepthAtEnqueue the same length — i.e. how many waiters were ahead of it.
	// Set by Enqueue; observability only.
	EnqueuePosition int
	DepthAtEnqueue  int
	// DrainTrigger is the bounded DrainTrigger* value naming the event whose
	// drain recorded this request's routing decision (reserved it, or failed it
	// terminally). Empty until a drain handles the request.
	DrainTrigger string
	DoneCh       chan struct{} // closed when the waiter is no longer interested
	doneOnce     sync.Once

	assignment requestqueue.Assignment[*Provider]

	// beforeAssignmentSend is a deterministic test seam for cancellation at
	// the exact reserve-to-waiter ownership boundary. Production requests leave
	// it nil.
	beforeAssignmentSend func()

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
	r.rejectAssignment()
}

func (r *QueuedRequest) Done() <-chan struct{} {
	r.init()
	return r.DoneCh
}

// offerAssignment publishes a scheduler-owned reservation. The scheduler keeps
// cleanup ownership until WaitForProviderContext explicitly accepts the offer.
// A waiter that already canceled rejects the offer before it can be published.
func (r *QueuedRequest) offerAssignment(provider *Provider, cleanup func()) bool {
	r.init()
	return r.assignment.Offer(r.DoneCh, provider, cleanup)
}

// acceptAssignment is the waiter acknowledgement that transfers reservation
// cleanup ownership from the scheduler to the dispatch caller.
func (r *QueuedRequest) acceptAssignment(provider *Provider) bool {
	return r.assignment.Accept(provider)
}

// rejectAssignment releases a scheduler-owned reservation exactly once. It is
// called by every cancellation/timeout path and may race offerAssignment.
func (r *QueuedRequest) rejectAssignment() { r.assignment.Reject() }

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

// WaitForProviderContext blocks until a provider is assigned, the timeout
// expires, or the context is cancelled.
func (q *RequestQueue) WaitForProviderContext(ctx context.Context, req *QueuedRequest) (*Provider, error) {
	req.init()
	timer := time.NewTimer(q.queue.MaxWait())
	defer timer.Stop()

	select {
	case p := <-req.ResponseCh:
		if p == nil {
			req.markDone()
			if req.FailureReason != nil {
				return nil, req.FailureReason
			}
			return nil, ErrQueueTimeout
		}
		if err := ctx.Err(); err != nil {
			req.markDone()
			return nil, err
		}
		if !req.EnqueuedAt.IsZero() && time.Since(req.EnqueuedAt) >= q.queue.MaxWait() {
			req.markDone()
			return nil, ErrQueueTimeout
		}
		if !req.acceptAssignment(p) {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			return nil, ErrQueueTimeout
		}
		req.markDone()
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

func (r *QueuedRequest) expireFromQueue() bool {
	r.markDone()
	select {
	case r.ResponseCh <- nil:
		return true
	default:
		return false
	}
}
