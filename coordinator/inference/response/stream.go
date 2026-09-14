package response

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"time"
)

func (s *Writer) Stream(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	if pr.ConsumerEndpoint == CompletionsEndpoint || pr.ConsumerEndpoint == MessagesEndpoint {
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
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "streaming not supported"))
		return
	}

	writeSSEResponseHeader(w, pr.RequestID)
	flusher.Flush()

	// Per-request relay state: the Responses-format latch, the held terminal
	// usage/finish frames, and the batch buffer. Every chunk — the ones already
	// consumed during dispatch and the ones relayed below — goes through the
	// same relay.handleChunk pipeline (see chat_stream_relay.go).
	relay := NewChatSink(pr, w, flusher, pr.Profile.Parent(), s.deps.Observer)

	// Write the chunks that were already consumed during dispatch (held
	// preamble first, then the committing content chunk).
	for _, firstChunk := range firstChunks {
		if firstChunk == "" {
			continue
		}
		relay.Chunk(firstChunk)
	}
	relay.Flush()
	if initialError != nil {
		s.writeChatStreamProviderError(w, flusher, pr, *initialError)
		return
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(InferenceTimeout)
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
		if s.deps.Reservation.Refund(pr, "provider_incomplete:"+pr.RequestID) {
			s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			s.deps.Outcomes.Incomplete(pr, true)
			s.ChatError(
				w, flusher, pr, "provider_error", "provider ended without completion")
			return
		}
		// Channel closed — inference complete.
		s.deps.Feedback.Success(pr)
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
				relay.Frame(out)
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
				relay.Frame(out)
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
			relay.Frame("data: " + string(sigEvent))
		}
		// Exactly one terminator, after every coordinator-appended event. The
		// terminal frames normally reach the wire together in one flush (the
		// relay splits a batch only at maxCoalescedBatchBytes).
		relay.Frame("data: [DONE]")
		relay.Flush()
		relay.Done()
	}

	// relayChunk forwards one provider chunk. Every chunk is a liveness
	// signal — re-arm the idle timeout up front, before deciding whether to
	// forward or hold it, so holding the terminal usage chunk still resets
	// the window that bounds the wait for the provider's inference_complete
	// (which closes ChunkCh after billing).
	relayChunk := func(chunk registry.ProviderChunk) {
		resetIdleTimer(timer, InferenceTimeout)
		relay.Chunk(chunk.Data)
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
			relay.Flush()
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
			relay.Flush()
			s.writeChatStreamProviderError(w, flusher, pr, errMsg)
			return

		case <-timer.C:
			s.deps.Reservation.Refund(pr, "provider_timeout:"+pr.RequestID)
			s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.deps.Outcomes.Timeout(pr, true, "")
			s.ChatError(w, flusher, pr, "timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, "after_commit")
			return
		}
	}
}

func (s *Writer) writeChatStreamProviderError(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	errMsg protocol.InferenceErrorMessage,
) {
	s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
	s.deps.Feedback.Error(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
	s.deps.Metrics.Incr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
	s.deps.Outcomes.ProviderError(pr, errMsg, true)
	s.ChatError(
		w, flusher, pr, "provider_error", ClientSafeInferenceErrorMessage(errMsg))
}
