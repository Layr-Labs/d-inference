package relay

import (
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Controller) handleGenericEndpointStreamingResponseWithError(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "streaming not supported"))
		return
	}
	inresp.WriteSSEResponseHeader(w, pr.RequestID)

	// The emitter flushes after every event; defer those flushes so a burst of
	// already-queued provider chunks reaches the wire in one Flush. Every
	// return path performs the owed flush.
	deferred := inresp.NewDeferredFlusher(flusher)
	defer deferred.FlushNow()

	emitter := inresp.NewGenericEndpointStreamEmitter(w, deferred, pr)
	emitter.Start()
	for _, chunk := range firstChunks {
		if chunk != "" {
			emitter.HandleChunk(inresp.SanitizeStreamCacheDetails(chunk))
		}
	}
	if initialError != nil {
		s.Refund(pr, "provider_error:"+pr.RequestID)
		s.Error(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause, initialError.CoordinatorCause)
		s.Observation.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.Outcome(pr, routeoutcome.PostCommitProviderErrorOutcome(pr, *initialError))
		emitter.EmitError("provider_error", failure.ClientSafeMessage(*initialError))
		return
	}
	// The preamble (start event + dispatch-time chunks) goes on the wire
	// before blocking on the provider.
	deferred.FlushNow()

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	// emitProviderError settles and reports an in-band provider error.
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.Refund(pr, "provider_error:"+pr.RequestID)
		s.Error(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
		s.Observation.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.Outcome(pr, routeoutcome.PostCommitProviderErrorOutcome(pr, errMsg))
		emitter.EmitError("provider_error", failure.ClientSafeMessage(errMsg))
	}

	// finishStream runs once ChunkCh is observed closed — on the blocking
	// receive or while draining already-queued chunks (after those were
	// flushed). A provider error is delivered on ErrorCh just before the
	// channels close, so it is checked first: a close must never turn a real
	// provider error into "incomplete".
	finishStream := func() {
		select {
		case errMsg, ok := <-pr.ErrorCh:
			if ok && errMsg.Error != "" {
				emitProviderError(errMsg)
				return
			}
		default:
		}
		var usage protocol.UsageInfo
		select {
		case complete, completeOK := <-pr.CompleteCh:
			if !completeOK {
				s.Refund(pr, "provider_incomplete:"+pr.RequestID)
				s.Outcome(pr, routeoutcome.PostCommitProviderIncompleteOutcome(pr))
				emitter.EmitError("provider_error", "provider ended without completion")
				return
			}
			usage = complete
		case <-time.After(2 * time.Second):
			s.Refund(pr, "provider_incomplete:"+pr.RequestID)
			s.Outcome(pr, routeoutcome.PostCommitProviderIncompleteOutcome(pr))
			emitter.EmitError("provider_error", "provider ended without completion")
			return
		case <-r.Context().Done():
			observation.ProfileClientGone(pr, phaseAfterCommit)
			return
		}
		s.Success(pr)
		emitter.Finish(usage)
	}

	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.HandleChunk(inresp.SanitizeStreamCacheDetails(chunk.Data))
		resetIdleTimer(timer, inferenceTimeout)
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				finishStream()
				return
			}
			relayChunk(providerChunk)
			// Fold in whatever the provider already queued behind this chunk
			// (never waiting for more), then flush the batch once. A close
			// observed mid-drain is handled exactly like the blocking-receive
			// close — after the drained chunks are on the wire.
			closed := DrainQueuedChunks(pr.ChunkCh, MaxCoalescedChunks-1, relayChunk)
			deferred.FlushNow()
			if closed {
				finishStream()
				return
			}

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			// Forward chunks queued ahead of the error before the terminal
			// event (see the chat relay for the rationale).
			DrainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			deferred.FlushNow()
			emitProviderError(errMsg)
			return

		case <-timer.C:
			s.Refund(pr, "provider_timeout:"+pr.RequestID)
			s.Observation.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.Outcome(pr, routeoutcome.PostCommitStreamTimeoutOutcome(pr))
			emitter.EmitError("timeout", "request timed out")
			return

		case <-r.Context().Done():
			observation.ProfileClientGone(pr, phaseAfterCommit)
			return
		}
	}
}
