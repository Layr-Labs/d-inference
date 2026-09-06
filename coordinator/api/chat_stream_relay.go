package api

// chatStreamRelay is the per-request state of the chat-completions SSE relay:
// the Responses-format detection latch, the held terminal usage/finish frames,
// and the batch buffer that coalesced chunks are written into before one
// Flush. handleChunk applies exactly the per-chunk pipeline the relay has
// always applied, in the same order; only the write/flush granularity changed.

import (
	"bytes"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

type chatStreamRelay struct {
	pr *registry.PendingRequest

	// w and flusher are the client sink every batch is written to, and stamps
	// records each flush in the request profile. The relay owns them so that
	// writeFrame can flush on its own when a batch reaches the byte cap.
	w       http.ResponseWriter
	flusher http.Flusher
	stamps  *relayStamps

	// sawResponsesAPI latches once a Responses API event is seen; from then on
	// chat-completions-specific handling (DONE swallowing, usage/finish holds,
	// normalizeSSEChunk, coordinator terminators) is skipped.
	sawResponsesAPI bool

	// pendingUsage is the held terminal include_usage chunk (parsed once); it
	// is re-emitted at stream end with the provider's authoritative reasoning
	// count spliced in. A zero-delta completion can make it the very first chunk.
	pendingUsage map[string]any

	// pendingFinish is the held chunk carrying the terminal finish_reason; the
	// coordinator re-derives "length" from the authoritative token counts
	// before forwarding it.
	pendingFinish map[string]any

	// buf accumulates the frames of one batch (each already framed with its
	// trailing blank line) until flush writes them in one call; frames counts
	// them so the relay stamps can keep chunks_out in SSE frames, not flushes.
	// The batch is bounded by maxCoalescedBatchBytes (see writeFrame), and
	// flush releases a backing array that grew past that bound.
	buf            bytes.Buffer
	frames         int
	contentWritten bool
	batchContent   bool
	batchTerminals responseTerminalObservations
}

func newChatStreamRelay(pr *registry.PendingRequest, w http.ResponseWriter, flusher http.Flusher, stamps *relayStamps) *chatStreamRelay {
	return &chatStreamRelay{pr: pr, w: w, flusher: flusher, stamps: stamps}
}

// handleChunk runs one provider chunk through the relay pipeline: Responses
// detection, provider-[DONE] swallowing, cache-detail/metadata stripping, the
// usage and finish holds, null-field normalization, and the public-model
// rewrite — appending the forwarded frame (if any) to the current batch.
func (rl *chatStreamRelay) handleChunk(chunk string) {
	if !rl.sawResponsesAPI && isResponsesAPIEventChunk(chunk) {
		rl.sawResponsesAPI = true
	}
	// Swallow provider-owned [DONE] events, including SSE groups decorated
	// with event/id/comment fields, while retaining any sibling event. The
	// coordinator appends terminal events of its own (held usage with the
	// reasoning breakdown, SE signature) and then emits exactly ONE [DONE] —
	// forwarding the provider's produced a stream shaped
	// `...usage, [DONE], signature, [DONE]`, and third-party SDKs treat the
	// first [DONE] as final (MacPaw/OpenAI then chokes parsing the signature
	// event).
	if !rl.sawResponsesAPI {
		chunk, _ = stripSSEDoneEvents(chunk)
		if strings.TrimSpace(chunk) == "" {
			return
		}
	}
	chunk = stripProviderChatMetadata(sanitizeStreamCacheDetails(chunk))
	if !rl.sawResponsesAPI {
		// Hold the terminal usage chunk (chat completions only) so the
		// reasoning breakdown can be spliced in at stream end; forwarding it
		// inline would emit it without reasoning_tokens.
		if obj, isUsage := parseUsageOnlyStreamChunk(chunk); isUsage {
			rl.pendingUsage = obj
			return
		}
		chunk = normalizeSSEChunk(chunk)
		// Hold the chunk carrying the terminal finish_reason so it can be
		// corrected to "length" against the authoritative token counts at
		// stream end (the provider engine always reports "stop").
		if obj, isFinish := parseFinishStreamChunk(chunk); isFinish {
			rl.pendingFinish = obj
			return
		}
	}
	rl.writeFrame(rewriteChunkModel(chunk, rl.pr))
}

// writeFrame appends one SSE frame (a "data: ..." payload without its
// trailing blank line) to the current batch. It is the only point at which
// bytes enter buf, so the byte cap is enforced here and covers every drain
// (the 32-chunk main-loop drain and the whole-channel drain ahead of a
// provider error alike): when appending would push the batch past
// maxCoalescedBatchBytes, the pending batch is flushed first. A single frame
// larger than the cap is still written whole — the batch then holds exactly
// that frame, the same peak the pre-coalescing per-chunk write had.
func (rl *chatStreamRelay) writeFrame(frame string) {
	if rl.buf.Len() > 0 && rl.buf.Len()+len(frame)+len("\n\n") > maxCoalescedBatchBytes {
		rl.flush()
	}
	if !rl.contentWritten && rl.stamps != nil && rl.stamps.accounting != nil && accountingChunkHasContent(frame) {
		rl.batchContent = true
	}
	if rl.stamps != nil && rl.stamps.accounting != nil {
		// Accounting recognizes terminal envelopes independently of the
		// wire-format latch, including an event-prefixed or grouped first chunk.
		terminals := accountingStreamTerminals(frame)
		rl.batchTerminals.observe(terminals.first)
		rl.batchTerminals.observe(terminals.conflicting)
	}
	rl.buf.WriteString(frame)
	rl.buf.WriteString("\n\n")
	rl.frames++
}

// flush writes the batched frames, if any, in one call and flushes once,
// recording the number of frames in the batch, the bytes the ResponseWriter
// accepted and the write error through relayStamps.wroteFrames so the request
// profile counts frames delivered and bytes actually accepted (a failed or
// short write marks client_write_err) exactly as it did when every frame was
// its own write. An empty batch neither writes nor flushes.
//
// A backing array that grew past maxCoalescedBatchBytes (an oversized frame,
// or bytes.Buffer's doubling overshooting the cap) is released rather than
// kept by Reset: a stream that once carried a large burst must not pin that
// allocation for the rest of its life.
func (rl *chatStreamRelay) flush() {
	if rl.buf.Len() == 0 {
		return
	}
	frames := rl.frames
	wanted := rl.buf.Len()
	n, err := rl.w.Write(rl.buf.Bytes())
	if rl.batchContent && err == nil && n == wanted {
		rl.stamps.content()
		rl.contentWritten = true
	}
	rl.batchContent = false
	if rl.batchTerminals.first != "" && err == nil && n == wanted {
		rl.stamps.accounting.Egress(true, false, rl.batchTerminals.first, rl.batchTerminals.conflicting)
	}
	rl.batchTerminals = responseTerminalObservations{}
	if n != wanted {
		rl.stamps.writeErr()
	}
	if rl.buf.Cap() > maxCoalescedBatchBytes {
		rl.buf = bytes.Buffer{}
	} else {
		rl.buf.Reset()
	}
	rl.frames = 0
	rl.flusher.Flush()
	rl.stamps.wroteFrames(frames, n, err)
}
