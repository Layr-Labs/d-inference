package api

// Byte-cap tests for the chat relay's coalesced batch (chatStreamRelay.buf):
// the batch is flushed before an append would push it past
// maxCoalescedBatchBytes, a backing array that outgrew the cap is released
// after the flush, and the consumer-visible byte stream is unchanged — the cap
// only moves flush boundaries.

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
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

// Frames whose total exceeds the cap go out in batches no larger than the cap,
// in order and byte-for-byte, the profile still counts every frame, and the
// buffer that carried them does not keep a backing array larger than the cap.
func TestChatStreamRelay_ByteCapFlushesBeforeAppendExceedsIt(t *testing.T) {
	w := newCapturingResponseWriter()
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	relay := newChatStreamRelay(&registry.PendingRequest{}, w, w, newRelayStamps(rp))

	// 100 KiB frames against the 256 KiB cap: two fit, the third would
	// overflow and forces the flush before it is appended.
	frame := "data: " + strings.Repeat("x", 100<<10)
	const n = 7
	var want strings.Builder
	for i := 0; i < n; i++ {
		relay.writeFrame(frame)
		want.WriteString(frame + "\n\n")
	}
	if w.flushes != 3 || w.writes != 3 {
		t.Fatalf("after %d frames: %d writes / %d flushes, want 3 / 3 (two frames per batch, one pending)", n, w.writes, w.flushes)
	}
	relay.flush()
	if w.flushes != 4 || w.writes != 4 {
		t.Fatalf("final flush: %d writes / %d flushes, want 4 / 4", w.writes, w.flushes)
	}
	if w.body.String() != want.String() {
		t.Fatalf("byte stream diverged: got %d bytes, want %d", w.body.Len(), want.Len())
	}
	if w.maxWrite > maxCoalescedBatchBytes {
		t.Fatalf("largest write = %d bytes, exceeds the %d-byte cap", w.maxWrite, maxCoalescedBatchBytes)
	}
	if got := relay.buf.Cap(); got > maxCoalescedBatchBytes {
		t.Fatalf("buffer retained %d bytes of capacity after the burst, want <= %d", got, maxCoalescedBatchBytes)
	}
	if rp.ChunksOut.Load() != n || rp.BytesOut.Load() != int64(want.Len()) {
		t.Fatalf("profile chunks_out=%d bytes_out=%d, want %d / %d", rp.ChunksOut.Load(), rp.BytesOut.Load(), n, want.Len())
	}
}

// A frame larger than the cap (a provider chunk near the 10 MiB read limit) is
// still relayed intact as one write — after the pending batch — and the buffer
// that held it is released rather than pinned for the rest of the stream.
func TestChatStreamRelay_OversizedFrameIsWrittenWholeAndReleased(t *testing.T) {
	w := newCapturingResponseWriter()
	relay := newChatStreamRelay(&registry.PendingRequest{}, w, w, nil)

	small := `data: {"a":1}`
	big := "data: " + strings.Repeat("y", 2*maxCoalescedBatchBytes)
	relay.writeFrame(small)
	relay.writeFrame(big)
	if w.writes != 1 || w.body.String() != small+"\n\n" {
		t.Fatalf("the pending frame must be flushed ahead of an oversized one: writes=%d body=%q", w.writes, w.body.String())
	}
	relay.flush()
	want := small + "\n\n" + big + "\n\n"
	if w.writes != 2 || w.flushes != 2 || w.body.String() != want {
		t.Fatalf("oversized frame: %d writes / %d flushes, body %d bytes; want 2 / 2 / %d", w.writes, w.flushes, w.body.Len(), len(want))
	}
	if w.maxWrite != len(big)+2 {
		t.Fatalf("oversized frame was not written whole: largest write = %d, want %d", w.maxWrite, len(big)+2)
	}
	if got := relay.buf.Cap(); got != 0 {
		t.Fatalf("buffer retained %d bytes of capacity after an oversized batch, want released", got)
	}
	// The relay keeps working on a fresh buffer.
	relay.writeFrame(small)
	relay.flush()
	if w.body.String() != want+small+"\n\n" {
		t.Fatalf("relay broken after releasing the buffer: %q", w.body.String())
	}
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
