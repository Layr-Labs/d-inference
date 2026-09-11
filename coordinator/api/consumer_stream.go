package api

import (
	"encoding/json"
	"net/http"
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
	if pr.ConsumerEndpoint == completionsEndpoint || pr.ConsumerEndpoint == messagesEndpoint || pr.IsResponsesAPI {
		s.handleEndpointStreamingResponse(w, r, pr, firstChunks, initialError)
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

	end, providerError := relayProviderStream(r.Context(), pr, timer, relayChunk, relay.flush)
	switch end {
	case providerStreamClosed:
		finishStream()
	case providerStreamFailed:
		s.writeChatStreamProviderError(w, flusher, pr, providerError)
	case providerStreamTimedOut:
		s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
		s.writeChatStreamTerminalError(w, flusher, pr, "timeout", "request timed out")
	case providerStreamClientGone:
		profileClientGone(pr, phaseAfterCommit)
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
