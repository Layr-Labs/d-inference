package attempt

import (
	"context"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"time"
)

const (
	// cancelWriteTimeout bounds how long a cancel write to the provider can
	// block. Using context.Background() unbounded here risks hanging the HTTP
	// handler goroutine when a WebSocket is half-dead.
	cancelWriteTimeout = 2 * time.Second
)

// SendCancel sends a Cancel message for the given request to the
// provider with a bounded timeout so a half-dead WebSocket doesn't hang the
// caller. It reports whether the frame was handed to the writer. Failures are
// logged at debug level because a disconnect race is the expected case — the
// provider may already be gone — but every one is metered
// (inference.cancel_send_failed{reason}) since a dropped cancel is the only
// silent-loss path on the coordinator side of cancel delivery.
//
// This is the raw primitive. Abandon paths that may leave the provider
// generating go through SendAbandonCancel / Cancel so the cancel is
// recorded for terminal correlation and zombie re-sends.
func (s Service) SendCancel(provider *registry.Provider, requestID string) bool {
	if provider == nil || provider.Conn == nil {
		return false
	}
	cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
	cancelData, err := json.Marshal(cancelMsg)
	if err != nil {
		s.deps.Logger().Error("failed to marshal cancel message", "request_id", requestID, "error", err)
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), cancelWriteTimeout)
	defer cancel()
	if err := provider.EnqueueText(ctx, cancelData); err != nil {
		s.deps.Metrics.Incr(MetricCancelSendFailed, []string{"reason:" + cancelSendFailureReason(err)})
		s.deps.Logger().Debug("failed to send cancel (provider may have disconnected)",
			"request_id", requestID, "error", err)
		return false
	}
	return true
}

// Cancel abandons a dispatch attempt that may still be generating
// (hedge loser, client gone before content): removes the pending request,
// marks the provider idle, sends a cancel over WebSocket so the provider stops,
// and refunds this attempt's provider-specific reservation top-up. cause is
// the bounded cancel cause recorded for terminal correlation.
//
// The cancel is sent only when THIS call removed a live pending record and no
// clean terminal has been ingressed for it. A missing record means a provider
// terminal already claimed the attempt (handleInferenceError removes pending
// before publishing on ErrorCh); a completion parked on the speculative
// empty-completion decision leaves the record but marks completion ingress.
// In both cases nothing is running provider-side, and cancelling would only
// cost the provider a no-op frame per request. Attempts whose terminal was
// observed by the caller use CancelAfterTerminal instead.
//
// The top-up refund only runs if THIS call actually removed the pending request
// (RemovePending returned non-nil). If settlement (handleComplete) already
// claimed it via its own RemovePending, we must not also refund — that would
// double-credit the consumer.
func (s Service) Cancel(provider *registry.Provider, pr *registry.PendingRequest, cause string) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	now := time.Now()
	// Record before RemovePending: a terminal racing this cleanup looks the
	// id up only after its own RemovePending returns nil, and must find the
	// entry rather than log the terminal as unknown.
	created, expired := s.deps.Tracker.record(pr.RequestID, pr.Model, cause, now)
	s.emitExpiredCancelEntries(expired)
	removed := provider.RemovePending(pr.RequestID)
	s.deps.Registry().SetProviderIdle(provider.ID)
	if removed != nil && !pr.HasCompletionIngress() {
		pr.Profile.Mark(registry.StampCancelSent)
		s.SendRecordedCancel(provider, pr.RequestID, pr.Model, cause)
	} else if created {
		s.deps.Tracker.forget(pr.RequestID)
	}
	if removed != nil {
		s.deps.Reservations().RefundProviderExtra(pr)
	}
}

// CancelAfterTerminal is Cancel for an attempt whose provider
// terminal the caller has already observed (ErrorCh value / ChunkCh closed).
// The terminal handler removed the pending record before publishing it, so
// nothing is running provider-side and no cancel frame is sent — only the
// speculative arbitration, idle transition and top-up refund remain.
func (s Service) CancelAfterTerminal(provider *registry.Provider, pr *registry.PendingRequest) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	removed := provider.RemovePending(pr.RequestID)
	s.deps.Registry().SetProviderIdle(provider.ID)
	if removed != nil {
		s.deps.Reservations().RefundProviderExtra(pr)
	}
}

// CancelForFirstContentTimeout atomically arbitrates timeout cleanup
// against provider ingress. false means an on-time event or another terminal
// already owns the request, so the wait loop must keep draining its channels.
func (s Service) CancelForFirstContentTimeout(
	provider *registry.Provider,
	pr *registry.PendingRequest,
) bool {
	if provider == nil || pr == nil {
		return false
	}
	now := time.Now()
	created, expired := s.deps.Tracker.record(pr.RequestID, pr.Model, CancelCauseFirstChunkTimeout, now)
	s.emitExpiredCancelEntries(expired)
	removed, deferred := provider.RemovePendingForFirstContentTimeout(pr.RequestID)
	if deferred || removed == nil {
		if created {
			s.deps.Tracker.forget(pr.RequestID)
		}
		return false
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	s.deps.Registry().SetProviderIdle(provider.ID)
	pr.Profile.Mark(registry.StampCancelSent)
	s.SendRecordedCancel(provider, pr.RequestID, pr.Model, CancelCauseFirstChunkTimeout)
	s.deps.Reservations().RefundProviderExtra(pr)
	return true
}
