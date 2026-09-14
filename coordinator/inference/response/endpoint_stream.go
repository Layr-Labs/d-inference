package response

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type streamCompletionPolicy uint8

const (
	// Messages and legacy Completions require an explicit completion message,
	// even when no balance was reserved. Client cancellation interrupts the wait.
	requireCompletionMessage streamCompletionPolicy = iota
	// Responses retains its historical fallback: missing usage is an error only
	// when an outstanding reservation can be refunded. Its usage grace period
	// completes independently of client cancellation.
	settledReservationCompletes
)

func (s *Writer) handleEndpointStreamingResponse(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "streaming not supported"))
		return
	}
	writeSSEResponseHeader(w, pr.RequestID)
	// Emitters write immediately but defer Flush so queued bursts reach the
	// wire together. Every terminal and early return flushes anything owed.
	deferred := newDeferredFlusher(flusher)
	defer deferred.flushNow()

	emitter, policy := newEndpointStreamEmitter(w, deferred, pr, s.deps.Observer)
	emitter.Start()
	for _, chunk := range firstChunks {
		if chunk != "" {
			emitter.Chunk(sanitizeStreamCacheDetails(chunk))
		}
	}
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
		s.deps.Feedback.Error(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
		s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.deps.Outcomes.ProviderError(pr, errMsg, true)
		emitter.Error("provider_error", ClientSafeInferenceErrorMessage(errMsg))
	}
	if initialError != nil {
		emitProviderError(*initialError)
		return
	}
	deferred.flushNow()

	timer := time.NewTimer(InferenceTimeout)
	defer timer.Stop()
	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.Chunk(sanitizeStreamCacheDetails(chunk.Data))
		resetIdleTimer(timer, InferenceTimeout)
	}
	end, providerError := relayProviderStream(r.Context(), pr, timer, relayChunk, deferred.flushNow)
	switch end {
	case providerStreamClosed:
		// A trailing error wins over completion, including a channel close
		// observed while draining a burst.
		select {
		case errMsg, ok := <-pr.ErrorCh:
			if ok && errMsg.Error != "" {
				emitProviderError(errMsg)
				return
			}
		default:
		}
		s.finishEndpointStream(r.Context(), pr, emitter, policy)
	case providerStreamFailed:
		emitProviderError(providerError)
	case providerStreamTimedOut:
		s.deps.Reservation.Refund(pr, "provider_timeout:"+pr.RequestID)
		s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
		s.deps.Outcomes.Timeout(pr, true, "")
		emitter.Error("timeout", "request timed out")
	case providerStreamClientGone:
		profileClientGone(pr, "after_commit")
	}
}

func newEndpointStreamEmitter(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, observer WriteObserver) (EndpointSink, streamCompletionPolicy) {
	// Explicit endpoint identity takes precedence over the Responses flag, as
	// it does in the request entry point.
	switch pr.ConsumerEndpoint {
	case MessagesEndpoint, CompletionsEndpoint:
		return NewEndpointSink(w, flusher, pr, observer), requireCompletionMessage
	}
	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	createdAt := time.Now().Unix()
	return NewResponsesSink(w, flusher, pr, responseID, createdAt, observer), settledReservationCompletes
}

func (s *Writer) finishEndpointStream(ctx context.Context, pr *registry.PendingRequest, emitter EndpointSink, policy streamCompletionPolicy) {
	var clientGone <-chan struct{}
	if policy == requireCompletionMessage {
		clientGone = ctx.Done()
	}
	var usage protocol.UsageInfo
	var completed bool
	select {
	case usage, completed = <-pr.CompleteCh:
	case <-time.After(2 * time.Second):
	case <-clientGone:
		profileClientGone(pr, "after_commit")
		return
	}
	if !completed {
		refunded := s.deps.Reservation.Refund(pr, "provider_incomplete:"+pr.RequestID)
		if policy == requireCompletionMessage || refunded {
			if policy == settledReservationCompletes {
				s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			}
			s.deps.Outcomes.Incomplete(pr, true)
			emitter.Error("provider_error", "provider ended without completion")
			return
		}
	}
	s.deps.Feedback.Success(pr)
	emitter.Finish(usage)
}
