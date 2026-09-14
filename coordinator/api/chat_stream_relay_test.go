package api

// Byte-cap tests for the chat relay's coalesced batch (chatStreamRelay.buf):
// the batch is flushed before an append would push it past
// maxCoalescedBatchBytes, a backing array that outgrew the cap is released
// after the flush, and the consumer-visible byte stream is unchanged — the cap
// only moves flush boundaries.

import (
	"bytes"
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// capturingResponseWriter is countingResponseWriter plus the body itself and
// the size of the largest single Write, so a test can pin both the bytes on
// the wire and the batch size each write carried.
type capturingResponseWriter struct {
	countingResponseWriter
	body     bytes.Buffer
	maxWrite int
}

func newCapturingResponseWriter() *capturingResponseWriter {
	return &capturingResponseWriter{countingResponseWriter: countingResponseWriter{header: make(http.Header)}}
}

func (w *capturingResponseWriter) Write(p []byte) (int, error) {
	if len(p) > w.maxWrite {
		w.maxWrite = len(p)
	}
	w.body.Write(p)
	return w.countingResponseWriter.Write(p)
}

// A prefilled burst of large chunks relayed through the chat streaming path
// never puts more than maxCoalescedBatchBytes in one write, costs more flushes
// than the chunk-count bound alone would allow (the byte cap engaged), and
// yields exactly the byte stream per-chunk relaying produces: every content
// chunk verbatim, the held finish chunk, and one [DONE].
func TestStreamRelay_ChatLargeBurstFlushesAtByteCap(t *testing.T) {
	const n = 40
	payload := strings.Repeat("z", 64<<10)
	s := newRelayBenchServer()
	pr := &registry.PendingRequest{
		RequestID:  "large-burst",
		Model:      burstTestModel,
		ChunkCh:    make(chan registry.ProviderChunk, n+8),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	var want strings.Builder
	for i := 0; i < n; i++ {
		chunk := chatContentChunk(payload + strconv.Itoa(i))
		pr.ChunkCh <- registry.ProviderChunk{Data: chunk}
		want.WriteString(chunk + "\n\n")
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: chatFinishChunk("stop")}
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: n}
	close(pr.CompleteCh)
	// The held finish chunk, re-emitted at stream end (finish_reason preserved:
	// no max_tokens bound), then exactly one terminator.
	want.WriteString(`data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"created":1700000000,"id":"chatcmpl-1","model":"` +
		burstTestModel + `","object":"chat.completion.chunk"}` + "\n\n")
	want.WriteString("data: [DONE]\n\n")

	w := newCapturingResponseWriter()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(context.Background())
	s.handleStreamingResponseWithFirstChunkAndError(w, r, pr, nil, nil)

	if w.status != http.StatusOK {
		t.Fatalf("status = %d", w.status)
	}
	if got := w.body.String(); got != want.String() {
		t.Fatalf("SSE stream diverged from per-chunk relaying: got %d bytes / %d events, want %d bytes / %d events",
			len(got), len(sseEvents([]byte(got))), want.Len(), len(sseEvents([]byte(want.String()))))
	}
	if w.maxWrite > maxCoalescedBatchBytes {
		t.Fatalf("largest write = %d bytes, exceeds the %d-byte cap", w.maxWrite, maxCoalescedBatchBytes)
	}
	// Count-only coalescing would fit n+1 frames in ceil((n+1)/32) batches;
	// the byte cap must have split them further.
	countOnlyFlushes := (n+1+maxCoalescedChunks-1)/maxCoalescedChunks + 2
	if w.flushes <= countOnlyFlushes {
		t.Fatalf("flushes = %d, want more than the count-only bound %d (byte cap did not engage)", w.flushes, countOnlyFlushes)
	}
	if minFlushes := want.Len() / maxCoalescedBatchBytes; w.flushes < minFlushes {
		t.Fatalf("flushes = %d, fewer than the %d batches %d bytes need at the cap", w.flushes, minFlushes, want.Len())
	}
}
