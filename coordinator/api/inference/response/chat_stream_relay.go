package response

import (
	"bytes"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type ChatStreamRelay struct {
	pr *registry.PendingRequest

	// w and flusher are the client sink every batch is written to, and stamps
	// records each flush in the request profile. The relay owns them so that
	// writeFrame can flush on its own when a batch reaches the byte cap.
	w       http.ResponseWriter
	flusher http.Flusher
	stamps  *observation.RelayStamps

	// sawResponsesAPI latches once a Responses API event is seen; from then on
	// chat-completions-specific handling (DONE swallowing, usage/finish holds,
	// normalizeSSEChunk, coordinator terminators) is skipped.
	SawResponsesAPI bool
	Identity        ChatStreamIdentity

	// pendingUsage is the held terminal include_usage chunk (parsed once); it
	// is re-emitted at stream end with the provider's authoritative reasoning
	// count spliced in. A zero-delta completion can make it the very first chunk.
	PendingUsage map[string]any

	// pendingFinish is the held chunk carrying the terminal finish_reason; the
	// coordinator re-derives "length" from the authoritative token counts
	// before forwarding it.
	PendingFinish map[string]any

	// buf accumulates the frames of one batch (each already framed with its
	// trailing blank line) until flush writes them in one call; frames counts
	// them so the relay stamps can keep chunks_out in SSE frames, not flushes.
	// The batch is bounded by maxCoalescedBatchBytes (see writeFrame), and
	// flush releases a backing array that grew past that bound.
	buf    bytes.Buffer
	frames int
}

func NewChatStreamRelay(pr *registry.PendingRequest, w http.ResponseWriter, flusher http.Flusher, stamps *observation.RelayStamps) *ChatStreamRelay {
	return &ChatStreamRelay{pr: pr, w: w, flusher: flusher, stamps: stamps}
}

// handleChunk runs one provider chunk through the relay pipeline: Responses
// detection, provider-[DONE] swallowing, cache-detail/metadata stripping, the
// usage and finish holds, null-field normalization, and the public-model
// rewrite — appending the forwarded frame (if any) to the current batch.
func (rl *ChatStreamRelay) HandleChunk(chunk string) {
	if !rl.SawResponsesAPI && isResponsesAPIEventChunk(chunk) {
		rl.SawResponsesAPI = true
	}
	// Swallow provider-owned [DONE] events, including SSE groups decorated
	// with event/id/comment fields, while retaining any sibling event. The
	// coordinator appends terminal events of its own (held usage with the
	// reasoning breakdown, SE signature) and then emits exactly ONE [DONE] —
	// forwarding the provider's produced a stream shaped
	// `...usage, [DONE], signature, [DONE]`, and third-party SDKs treat the
	// first [DONE] as final (MacPaw/OpenAI then chokes parsing the signature
	// event).
	if !rl.SawResponsesAPI {
		chunk, _ = stripSSEDoneEvents(chunk)
		if strings.TrimSpace(chunk) == "" {
			return
		}
	}
	chunk = stripProviderChatMetadata(SanitizeStreamCacheDetails(chunk))
	if !rl.SawResponsesAPI {
		rl.Identity.observe(chunk)
		// Hold the terminal usage chunk (chat completions only) so the
		// reasoning breakdown can be spliced in at stream end; forwarding it
		// inline would emit it without reasoning_tokens.
		if obj, isUsage := parseUsageOnlyStreamChunk(chunk); isUsage {
			rl.PendingUsage = obj
			return
		}
		chunk = normalizeSSEChunk(chunk)
		// Hold the chunk carrying the terminal finish_reason so it can be
		// corrected to "length" against the authoritative token counts at
		// stream end (the provider engine always reports "stop").
		if obj, isFinish := parseFinishStreamChunk(chunk); isFinish {
			rl.PendingFinish = obj
			return
		}
	}
	rl.WriteFrame(rewriteChunkModel(chunk, rl.pr))
}

// writeFrame appends one SSE frame (a "data: ..." payload without its
// trailing blank line) to the current batch. It is the only point at which
// bytes enter buf, so the byte cap is enforced here and covers every drain
// (the 32-chunk main-loop drain and the whole-channel drain ahead of a
// provider error alike): when appending would push the batch past
// maxCoalescedBatchBytes, the pending batch is flushed first. A single frame
// larger than the cap is still written whole — the batch then holds exactly
// that frame, the same peak the pre-coalescing per-chunk write had.
func (rl *ChatStreamRelay) WriteFrame(frame string) {
	if rl.buf.Len() > 0 && rl.buf.Len()+len(frame)+len("\n\n") > maxCoalescedBatchBytes {
		rl.Flush()
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
func (rl *ChatStreamRelay) Flush() {
	if rl.buf.Len() == 0 {
		return
	}
	frames := rl.frames
	size := rl.buf.Len()
	content := observation.GeneratedContentSSE(rl.buf.Bytes())
	n, err := rl.w.Write(rl.buf.Bytes())
	observation.MarkContentWrite(rl.w, content, n, size, err)
	observation.MarkResponseTerminalWrite(rl.w, observation.ResponseStreamTerminals(rl.buf.Bytes()), n, size, err)
	if n != size {
		rl.stamps.WriteErr()
	}
	if rl.buf.Cap() > maxCoalescedBatchBytes {
		rl.buf = bytes.Buffer{}
	} else {
		rl.buf.Reset()
	}
	rl.frames = 0
	rl.flusher.Flush()
	rl.stamps.WroteFrames(frames, n, err)
}
