package api

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// endpointStreamEmitter translates provider chat chunks into one consumer wire
// format. Transport, error settlement and completion policy live outside it.
type endpointStreamEmitter interface {
	start()
	handleChunk(string)
	finish(protocol.UsageInfo)
	emitError(string, string)
}

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

func (s *Server) handleEndpointStreamingResponse(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}
	writeSSEResponseHeader(w, pr.RequestID)
	// Emitters write immediately but defer Flush so queued bursts reach the
	// wire together. Every terminal and early return flushes anything owed.
	deferred := newDeferredFlusher(flusher)
	defer deferred.flushNow()

	emitter, policy := newEndpointStreamEmitter(w, deferred, pr)
	emitter.start()
	for _, chunk := range firstChunks {
		if chunk != "" {
			emitter.handleChunk(sanitizeStreamCacheDetails(chunk))
		}
	}
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(errMsg))
	}
	if initialError != nil {
		emitProviderError(*initialError)
		return
	}
	deferred.flushNow()

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()
	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.handleChunk(sanitizeStreamCacheDetails(chunk.Data))
		resetIdleTimer(timer, inferenceTimeout)
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
		s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
		emitter.emitError("timeout", "request timed out")
	case providerStreamClientGone:
		profileClientGone(pr, phaseAfterCommit)
	}
}

func newEndpointStreamEmitter(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest) (endpointStreamEmitter, streamCompletionPolicy) {
	// Explicit endpoint identity takes precedence over the Responses flag, as
	// it does in the request entry point.
	switch pr.ConsumerEndpoint {
	case messagesEndpoint:
		return newMessagesStreamEmitter(w, flusher, pr), requireCompletionMessage
	case completionsEndpoint:
		return &completionsStreamEmitter{w: w, flusher: flusher, pr: pr, stamps: newRelayStamps(pr.Profile.Parent())}, requireCompletionMessage
	}
	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	return newResponsesStreamEmitter(w, flusher, pr, responseID, time.Now().Unix()), settledReservationCompletes
}

func (s *Server) finishEndpointStream(ctx context.Context, pr *registry.PendingRequest, emitter endpointStreamEmitter, policy streamCompletionPolicy) {
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
		profileClientGone(pr, phaseAfterCommit)
		return
	}
	if !completed {
		refunded := s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
		if policy == requireCompletionMessage || refunded {
			if policy == settledReservationCompletes {
				s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			}
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
			emitter.emitError("provider_error", "provider ended without completion")
			return
		}
	}
	s.noteInferenceSuccess(pr)
	emitter.finish(usage)
}
