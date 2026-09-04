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
	// alias rewrites the concrete build id back to the public alias in
	// forwarded frames; needles are built once per request, not per chunk.
	alias modelAliasRewriter

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
	// trailing blank line) until flush writes them in one call.
	buf bytes.Buffer
	// frames counts the SSE frames in buf, so flush can credit the profiler
	// one chunk per frame rather than one per write.
	frames int
}

func newChatStreamRelay(pr *registry.PendingRequest) *chatStreamRelay {
	return &chatStreamRelay{pr: pr, alias: newModelAliasRewriter(pr)}
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
	rl.writeFrame(rl.alias.rewrite(chunk))
}

// writeFrame appends one SSE frame (a "data: ..." payload without its
// trailing blank line) to the current batch.
func (rl *chatStreamRelay) writeFrame(frame string) {
	rl.buf.WriteString(frame)
	rl.buf.WriteString("\n\n")
	rl.frames++
}

// flush writes the batched frames, if any, in one call and flushes once. It
// reports the write outcome — bytes accepted, the number of SSE frames the
// batch carried, and the write error — so the caller can feed the
// system-profiler relay stamps (relayStamps.wroteFrames) exactly as the
// per-chunk relay did: chunks_out is credited per frame, never per write or
// flush, so coalescing is invisible to the profile.
func (rl *chatStreamRelay) flush(w http.ResponseWriter, flusher http.Flusher) (n, frames int, err error) {
	if rl.buf.Len() == 0 {
		return 0, 0, nil
	}
	frames = rl.frames
	n, err = w.Write(rl.buf.Bytes())
	rl.buf.Reset()
	rl.frames = 0
	flusher.Flush()
	return n, frames, err
}
