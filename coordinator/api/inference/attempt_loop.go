package inference

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
)

func (d *dispatchState) newAttemptLoop() *attempt.Loop {
	return attempt.NewLoop(attempt.LoopOperations{
		Begin:   func(index int) { d.attempt = index },
		Expired: d.firstTokenExpired,
		Deadline: func() {
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
		},
		ResetPreamble: func() { d.heldChunks = nil },
		Dispatch:      d.selectPrimary,
		Ready:         d.primaryReady,
		ExpiredInflight: func() attempt.Outcome {
			if chunk, ok := firstcontent.DrainReadyFirstContent(d.pr, &d.heldChunks); ok {
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				return attempt.Committed
			}
			if d.abandonInflightForFirstTokenTimeout() {
				return attempt.FailFast
			}
			return attempt.Proceed
		},
		FirstContent:  d.waitFirstChunk,
		Accepted:      d.waitAccepted,
		RetryDecision: d.retryDecision,
		ClientGone: func() {
			d.refundReservation()
			d.emitClientGone(phaseBeforeFirstToken)
		},
	}, maxDispatchAttempts)
}

func (d *dispatchState) primaryReady() {
	s := d.s
	d.requestID = d.pr.RequestID
	// Attempt is stamped before the provider send; do not mutate it here where
	// completion may already be running concurrently.
	if d.timing.RoutedAt.IsZero() {
		d.timing.RoutedAt = time.Now()
	}
	d.emitRouteLatency()
	s.observation.Incr("routing.decisions", []string{"model:" + d.model, "outcome:selected"})
	s.observation.Incr("routing.provider_selected", []string{"provider_id:" + d.provider.ID, "model:" + d.model})
	s.logger.Info("inference request dispatched",
		"trace_id", access.RequestIDFromContext(d.r.Context()),
		"request_id", d.requestID,
		"model", d.model,
		"provider_id", d.provider.ID,
		"stream", d.stream,
		"attempt", d.attempt+1,
	)
	s.logger.Info("dispatch_pool",
		"model", d.model,
		"ttft_deadline_ms", d.deadline.Milliseconds(),
		"speculative_at_ms", d.speculativeAt.Milliseconds(),
	)
}
