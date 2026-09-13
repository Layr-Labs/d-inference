package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) handleStreamingResponseWithFirstChunkAndError(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	if pr.ConsumerEndpoint == completionsEndpoint || pr.ConsumerEndpoint == messagesEndpoint {
		s.handleGenericEndpointStreamingResponseWithError(
			w, r, pr, firstChunks, initialError)
		return
	}
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(
			w, r, pr, firstChunks, initialError)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	writeSSEResponseHeader(w, pr.RequestID)
	flusher.Flush()
	rs := newRelayStamps(pr.Profile.Parent())

	// Per-request relay state: the Responses-format latch, the held terminal
	// usage/finish frames, and the batch buffer. Every chunk — the ones already
	// consumed during dispatch and the ones relayed below — goes through the
	// same relay.handleChunk pipeline (see chat_stream_relay.go).
	relay := newChatStreamRelay(pr, w, flusher, rs)

	// Write the chunks that were already consumed during dispatch (held
	// preamble first, then the committing content chunk).
	for _, firstChunk := range firstChunks {
		if firstChunk == "" {
			continue
		}
		relay.handleChunk(firstChunk)
	}
	relay.flush()
	if initialError != nil {
		s.writeChatStreamProviderError(w, flusher, pr, *initialError)
		return
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	// finishStream runs once ChunkCh is observed closed — on the blocking
	// receive or while draining already-queued chunks (after those were
	// flushed): surface a trailing provider error, refund an incomplete stream,
	// or emit the held finish/usage frames and the single [DONE].
	finishStream := func() {
		select {
		case errMsg, ok := <-pr.ErrorCh:
			if ok && errMsg.Error != "" {
				s.writeChatStreamProviderError(w, flusher, pr, errMsg)
				return
			}
		default:
		}
		if s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
			s.writeChatStreamTerminalError(
				w, flusher, pr, "provider_error", "provider ended without completion")
			return
		}
		// Channel closed — inference complete.
		s.noteInferenceSuccess(pr)
		// For Responses API streams, the provider already sent
		// "response.completed" as the terminal event. Adding
		// extra chunks would break SDK parsers.
		if relay.sawResponsesAPI {
			return
		}
		// Emit the held finish/usage chunks with the authoritative token
		// counts (CompleteCh) spliced in: the finish chunk gets its
		// finish_reason corrected to "length" when generation hit the
		// max-tokens bound, and the usage chunk gets the reasoning
		// breakdown. This select runs once, at stream end: the provider's
		// inferenceComplete (which populates CompleteCh) is what ends the
		// stream, so it is effectively already buffered — the timeout is a
		// fallback, not a hot-path wait.
		var usage protocol.UsageInfo
		if relay.pendingUsage != nil || relay.pendingFinish != nil {
			select {
			case u, uok := <-pr.CompleteCh:
				if uok {
					usage = u
				}
			case <-time.After(2 * time.Second):
			case <-r.Context().Done():
			}
		}
		if relay.pendingFinish != nil {
			if out := finalizeFinishChunk(relay.pendingFinish, usage, pr); out != "" {
				relay.writeFrame(out)
			}
		}
		if relay.pendingUsage != nil {
			// Ride the SE signature on the held usage chunk (a complete,
			// well-formed chat.completion.chunk) instead of emitting a
			// separate bare event that strict SDK parsers reject.
			if pr.SESignature != "" {
				relay.pendingUsage["se_signature"] = pr.SESignature
				relay.pendingUsage["response_hash"] = pr.ResponseHash
			}
			attachChatCompletionMetadata(relay.pendingUsage, pr)
			if out := finalizeUsageChunk(relay.pendingUsage, usage, pr); out != "" {
				relay.writeFrame(out)
			}
		} else if pr.SESignature != "" || hasChatCompletionMetadata(pr) {
			// No held usage chunk to ride on: emit the signature and/or
			// opt-in metadata as a fully-shaped chat.completion.chunk
			// (id/object/created/model/choices) so strict decoders parse
			// it; the extra fields are additive. It precedes the single
			// [DONE] below.
			event := newChatCompletionExtrasEvent(pr)
			if pr.SESignature != "" {
				event["se_signature"] = pr.SESignature
				event["response_hash"] = pr.ResponseHash
			}
			attachChatCompletionMetadata(event, pr)
			sigEvent, _ := json.Marshal(event)
			relay.writeFrame("data: " + string(sigEvent))
		}
		// Exactly one terminator, after every coordinator-appended event. The
		// terminal frames normally reach the wire together in one flush (the
		// relay splits a batch only at maxCoalescedBatchBytes).
		relay.writeFrame("data: [DONE]")
		relay.flush()
		rs.done()
	}

	// relayChunk forwards one provider chunk. Every chunk is a liveness
	// signal — re-arm the idle timeout up front, before deciding whether to
	// forward or hold it, so holding the terminal usage chunk still resets
	// the window that bounds the wait for the provider's inference_complete
	// (which closes ChunkCh after billing).
	relayChunk := func(chunk registry.ProviderChunk) {
		resetIdleTimer(timer, inferenceTimeout)
		relay.handleChunk(chunk.Data)
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
			closed := drainQueuedChunks(pr.ChunkCh, maxCoalescedChunks-1, relayChunk)
			relay.flush()
			if closed {
				finishStream()
				return
			}

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			// The provider error is delivered before ChunkCh is closed, so
			// chunks that arrived ahead of it may still be queued: forward them
			// (never waiting) before the terminal error so a late failure never
			// truncates content the provider already produced.
			drainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			relay.flush()
			s.writeChatStreamProviderError(w, flusher, pr, errMsg)
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			s.writeChatStreamTerminalError(w, flusher, pr, "timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, phaseAfterCommit)
			return
		}
	}
}

func (s *Server) writeChatStreamProviderError(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	errMsg protocol.InferenceErrorMessage,
) {
	s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
	s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
	s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
	s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
	s.writeChatStreamTerminalError(
		w, flusher, pr, "provider_error", clientSafeInferenceErrorMessage(errMsg))
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(
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

	// The emitter flushes after every event; defer those flushes so a burst of
	// already-queued provider chunks reaches the wire in one Flush. Every
	// return path performs the owed flush.
	deferred := newDeferredFlusher(flusher)
	defer deferred.flushNow()

	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	createdAt := time.Now().Unix()
	emitter := newResponsesStreamEmitter(w, deferred, pr, responseID, createdAt)
	emitter.start()

	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			emitter.handleChunk(sanitizeStreamCacheDetails(firstChunk))
		}
	}
	if initialError != nil {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause, initialError.CoordinatorCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, *initialError))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(*initialError))
		return
	}
	// The preamble (lifecycle events + dispatch-time chunks) goes on the wire
	// before blocking on the provider.
	deferred.flushNow()

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	// emitProviderError settles and reports an in-band provider error.
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(errMsg))
	}

	// finishStream runs once ChunkCh is observed closed — on the blocking
	// receive or while draining already-queued chunks (after those were
	// flushed). A provider error is delivered on ErrorCh just before the
	// channels close, so it is checked first: a close must never turn a real
	// provider error into "incomplete" (or, with nothing reserved, success).
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
		completed := false
		select {
		case u, ok := <-pr.CompleteCh:
			if ok {
				usage = u
				completed = true
			}
		case <-time.After(2 * time.Second):
		}
		if !completed && s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
			emitter.emitError("provider_error", "provider ended without completion")
			return
		}
		s.noteInferenceSuccess(pr)
		emitter.finish(usage)
	}

	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.handleChunk(sanitizeStreamCacheDetails(chunk.Data))
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
			closed := drainQueuedChunks(pr.ChunkCh, maxCoalescedChunks-1, relayChunk)
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
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			emitter.emitError("timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, phaseAfterCommit)
			return
		}
	}
}
