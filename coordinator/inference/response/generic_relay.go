package response

import (
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"time"
)

func (s *Writer) handleGenericEndpointStreamingResponseWithError(
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

	// The emitter flushes after every event; defer those flushes so a burst of
	// already-queued provider chunks reaches the wire in one Flush. Every
	// return path performs the owed flush.
	deferred := newDeferredFlusher(flusher)
	defer deferred.flushNow()

	emitter := NewEndpointSink(w, deferred, pr, s.deps.Observer)
	emitter.Start()
	for _, chunk := range firstChunks {
		if chunk != "" {
			emitter.Chunk(sanitizeStreamCacheDetails(chunk))
		}
	}
	if initialError != nil {
		s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
		s.deps.Feedback.Error(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause, initialError.CoordinatorCause)
		s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.deps.Outcomes.ProviderError(pr, *initialError, true)
		emitter.Error("provider_error", ClientSafeInferenceErrorMessage(*initialError))
		return
	}
	// The preamble (start event + dispatch-time chunks) goes on the wire
	// before blocking on the provider.
	deferred.flushNow()

	timer := time.NewTimer(InferenceTimeout)
	defer timer.Stop()

	// emitProviderError settles and reports an in-band provider error.
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
		s.deps.Feedback.Error(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
		s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.deps.Outcomes.ProviderError(pr, errMsg, true)
		emitter.Error("provider_error", ClientSafeInferenceErrorMessage(errMsg))
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
				s.deps.Reservation.Refund(pr, "provider_incomplete:"+pr.RequestID)
				s.deps.Outcomes.Incomplete(pr, true)
				emitter.Error("provider_error", "provider ended without completion")
				return
			}
			usage = complete
		case <-time.After(2 * time.Second):
			s.deps.Reservation.Refund(pr, "provider_incomplete:"+pr.RequestID)
			s.deps.Outcomes.Incomplete(pr, true)
			emitter.Error("provider_error", "provider ended without completion")
			return
		case <-r.Context().Done():
			profileClientGone(pr, "after_commit")
			return
		}
		s.deps.Feedback.Success(pr)
		emitter.Finish(usage)
	}

	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.Chunk(sanitizeStreamCacheDetails(chunk.Data))
		resetIdleTimer(timer, InferenceTimeout)
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
			closed := drainQueuedChunks(pr.ChunkCh, MaxBatchChunks-1, relayChunk)
			deferred.flushNow()
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
			drainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			deferred.flushNow()
			emitProviderError(errMsg)
			return

		case <-timer.C:
			s.deps.Reservation.Refund(pr, "provider_timeout:"+pr.RequestID)
			s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.deps.Outcomes.Timeout(pr, true, "")
			emitter.Error("timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, "after_commit")
			return
		}
	}
}
