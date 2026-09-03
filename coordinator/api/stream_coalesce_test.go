package api

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// drainQueuedChunks pulls only what is already queued, in order, never more
// than the budget, and reports a close it runs into without invoking fn.
func TestDrainQueuedChunks(t *testing.T) {
	t.Run("stops at budget and preserves order", func(t *testing.T) {
		ch := make(chan registry.ProviderChunk, 8)
		for i := 0; i < 5; i++ {
			ch <- registry.ProviderChunk{Data: string(rune('a' + i))}
		}
		var got []string
		closed := drainQueuedChunks(ch, 3, func(c registry.ProviderChunk) { got = append(got, c.Data) })
		if closed {
			t.Fatal("open channel reported closed")
		}
		if want := []string{"a", "b", "c"}; len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
			t.Fatalf("drained %v, want %v", got, want)
		}
		if len(ch) != 2 {
			t.Fatalf("channel should retain the 2 chunks beyond the budget, has %d", len(ch))
		}
	})

	t.Run("empty channel drains nothing without blocking", func(t *testing.T) {
		ch := make(chan registry.ProviderChunk, 1)
		done := make(chan struct{})
		var n int
		go func() {
			defer close(done)
			if drainQueuedChunks(ch, 31, func(registry.ProviderChunk) { n++ }) {
				t.Error("open empty channel reported closed")
			}
		}()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("drain blocked on an empty channel")
		}
		if n != 0 {
			t.Fatalf("drained %d chunks from an empty channel", n)
		}
	})

	t.Run("close mid-drain is reported after the queued chunks", func(t *testing.T) {
		ch := make(chan registry.ProviderChunk, 8)
		ch <- registry.ProviderChunk{Data: "x"}
		ch <- registry.ProviderChunk{Data: "y"}
		close(ch)
		var got []string
		closed := drainQueuedChunks(ch, 31, func(c registry.ProviderChunk) { got = append(got, c.Data) })
		if !closed {
			t.Fatal("closed channel not reported")
		}
		if len(got) != 2 || got[0] != "x" || got[1] != "y" {
			t.Fatalf("drained %v before the close, want [x y]", got)
		}
	})
}

type countingFlusher struct{ n int }

func (f *countingFlusher) Flush() { f.n++ }

// deferredFlusher collapses any number of emitter flushes into one real flush
// and flushes nothing when nothing was written.
func TestDeferredFlusher(t *testing.T) {
	inner := &countingFlusher{}
	d := newDeferredFlusher(inner)

	d.flushNow()
	if inner.n != 0 {
		t.Fatalf("flushNow with nothing owed flushed %d times", inner.n)
	}
	for i := 0; i < 40; i++ {
		d.Flush()
	}
	d.flushNow()
	d.flushNow()
	if inner.n != 1 {
		t.Fatalf("40 deferred flushes should cost exactly 1 real flush, got %d", inner.n)
	}
	d.Flush()
	d.flushNow()
	if inner.n != 2 {
		t.Fatalf("a new owed flush after flushNow should flush again, got %d", inner.n)
	}
}

// A provider error delivered just before the channels close (the provider
// side does `ErrorCh <- msg` and then closes ChunkCh) must be reported by
// every relay as the in-band provider error — even when the close is observed
// while draining queued chunks — never as an incomplete or completed stream,
// and only after every queued delta has been forwarded.
func TestStreamRelay_BufferedErrorBeforeCloseIsReported(t *testing.T) {
	const n = 5
	s := newRelayBenchServer()
	for _, variant := range relayVariants {
		t.Run(variant, func(t *testing.T) {
			pr := &registry.PendingRequest{
				RequestID:  "err-req",
				Model:      burstTestModel,
				ChunkCh:    make(chan registry.ProviderChunk, 16),
				CompleteCh: make(chan protocol.UsageInfo, 1),
				ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
			}
			switch variant {
			case "responses":
				pr.IsResponsesAPI = true
			case "completions":
				pr.ConsumerEndpoint = completionsEndpoint
			case "messages":
				pr.ConsumerEndpoint = messagesEndpoint
			}
			for i := 0; i < n; i++ {
				pr.ChunkCh <- registry.ProviderChunk{Data: chatContentChunk("x" + strconv.Itoa(i) + "z")}
			}
			pr.ErrorCh <- protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   pr.RequestID,
				Error:       "engine crashed mid-generation",
				StatusCode:  http.StatusInternalServerError,
				FailureCode: protocol.FailureCodeGenerationFailure,
			}
			close(pr.ChunkCh)
			close(pr.CompleteCh)

			rec := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			s.handleStreamingResponseWithFirstChunkAndError(rec, r, pr, nil, nil)

			body := rec.Body.String()
			for i := 0; i < n; i++ {
				if !strings.Contains(body, "x"+strconv.Itoa(i)+"z") {
					t.Fatalf("delta %d missing from stream: %q", i, body)
				}
			}
			events := sseEvents(rec.Body.Bytes())
			last := events[len(events)-1]
			if !strings.Contains(last, `"error"`) {
				t.Fatalf("last frame should be the provider error: %q", last)
			}
			for _, marker := range []string{
				"[DONE]", "response.completed", "response.incomplete", "message_stop",
				"provider ended without completion",
			} {
				if strings.Contains(body, marker) {
					t.Fatalf("errored stream must not carry %q: %q", marker, body)
				}
			}
		})
	}
}

// A 200-chunk prefilled burst (the worst case for per-chunk flushing) costs
// at most ceil(chunks/maxCoalescedChunks) batch flushes plus the header and
// terminal flushes, for every streaming variant — and the byte count is
// unchanged from one-flush-per-chunk relaying.
func TestStreamRelay_FlushCountBounded(t *testing.T) {
	const n = 200
	s := newRelayBenchServer()
	// n content chunks + 1 finish chunk, in batches of maxCoalescedChunks.
	batches := (n + 1 + maxCoalescedChunks - 1) / maxCoalescedChunks
	// header/preamble flush + batch flushes + terminal flush.
	maxFlushes := batches + 2
	for _, variant := range relayVariants {
		t.Run(variant, func(t *testing.T) {
			w := relayBurstCounts(s, n, variant)
			if w.status != 200 {
				t.Fatalf("status = %d", w.status)
			}
			if w.flushes > maxFlushes {
				t.Fatalf("flushes = %d, want <= %d for %d chunks", w.flushes, maxFlushes, n+1)
			}
			if w.flushes < batches {
				t.Fatalf("flushes = %d, fewer than the %d batches (a flush was skipped)", w.flushes, batches)
			}
			if w.bytes == 0 {
				t.Fatal("no bytes written")
			}
		})
	}
}

// newPrefilledGoldenChatRequest queues the golden 50-chunk chat burst
// (burstChatChunks, stream_burst_test.go) on a closed channel with the
// provider's usage (reasoning=7) already delivered, mirroring the HTTP golden
// test's request (max_tokens 1000) so the wire stream is byte-identical.
func newPrefilledGoldenChatRequest() *registry.PendingRequest {
	chunks := burstChatChunks(50)
	pr := &registry.PendingRequest{
		RequestID:          "golden-req",
		Model:              burstTestModel,
		RequestedMaxTokens: 1000,
		ChunkCh:            make(chan registry.ProviderChunk, len(chunks)+1),
		CompleteCh:         make(chan protocol.UsageInfo, 1),
		ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
	}
	for _, c := range chunks {
		pr.ChunkCh <- registry.ProviderChunk{Data: c}
	}
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 7}
	close(pr.CompleteCh)
	return pr
}

// The system-profiler egress stamps count SSE frames, never writes or
// flushes. The coalesced chat relay writes a whole batch per call, so a
// per-write tally would under-report chunks_out against the per-frame generic
// emitters; every variant must leave chunks_out equal to the SSE events on the
// wire, bytes_out equal to the bytes written, and no client_write_err.
func TestStreamRelay_ProfileCountsFramesNotFlushes(t *testing.T) {
	s := newRelayBenchServer()

	// The golden chat stream: the direct harness reproduces the byte-identical
	// wire stream and the profile carries its exact byte count and its 53
	// frames (50 deltas + held finish + held usage + [DONE]).
	t.Run("chat-golden", func(t *testing.T) {
		rp := registry.NewRequestProfile(time.Now(), "coord-golden", nil, 0)
		pr := newPrefilledGoldenChatRequest()
		pr.Profile = rp.NewAttempt(pr.RequestID, 1, "")
		rec := httptest.NewRecorder()
		s.handleStreamingResponseWithFirstChunkAndError(rec, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr, nil, nil)
		if got := rec.Body.String(); got != chatBurstGolden {
			t.Fatalf("SSE stream diverged from golden.\n--- got ---\n%q\n--- want ---\n%q", got, chatBurstGolden)
		}
		if got := rp.BytesOut.Load(); got != int64(len(chatBurstGolden)) {
			t.Fatalf("bytes_out = %d, want golden %d", got, len(chatBurstGolden))
		}
		if got := rp.ChunksOut.Load(); got != 53 {
			t.Fatalf("chunks_out = %d, want 53 (one per SSE frame)", got)
		}
		if rp.ClientWriteErr.Load() {
			t.Fatal("client_write_err set on a clean stream")
		}
	})

	const n = 200
	for _, variant := range relayVariants {
		t.Run(variant+"-200", func(t *testing.T) {
			rp := registry.NewRequestProfile(time.Now(), "coord-"+variant, nil, 0)
			pr := newPrefilledBurstRequest(n, variant)
			pr.Profile = rp.NewAttempt(pr.RequestID, 1, "")
			rec := httptest.NewRecorder()
			s.handleStreamingResponseWithFirstChunkAndError(rec, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr, nil, nil)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d", rec.Code)
			}
			body := rec.Body.Bytes()
			events := sseEvents(body)
			if variant == "chat" && len(events) != n+2 {
				// 200 deltas + the held finish chunk + [DONE]: a count no
				// per-flush tally could reach.
				t.Fatalf("chat frames on the wire = %d, want %d", len(events), n+2)
			}
			if got := rp.ChunksOut.Load(); got != int64(len(events)) {
				t.Fatalf("chunks_out = %d, want %d (one per SSE frame on the wire)", got, len(events))
			}
			if got := rp.BytesOut.Load(); got != int64(len(body)) {
				t.Fatalf("bytes_out = %d, want %d", got, len(body))
			}
			if rp.ClientWriteErr.Load() {
				t.Fatal("client_write_err set on a clean stream")
			}
			if rp.FirstFlushUS.Load() == 0 || rp.LastFlushUS.Load() == 0 || rp.DoneFlushedUS.Load() == 0 {
				t.Fatalf("egress stamps missing: first=%d last=%d done=%d",
					rp.FirstFlushUS.Load(), rp.LastFlushUS.Load(), rp.DoneFlushedUS.Load())
			}
		})
	}
}

// failingResponseWriter accepts headers and flushes but rejects every body
// write, like a client whose connection has gone away.
type failingResponseWriter struct {
	header http.Header
	status int
}

func (w *failingResponseWriter) Header() http.Header  { return w.header }
func (w *failingResponseWriter) WriteHeader(code int) { w.status = code }
func (w *failingResponseWriter) Write([]byte) (int, error) {
	return 0, errors.New("write: broken pipe")
}
func (w *failingResponseWriter) Flush() {}

// A ResponseWriter that fails the writes marks client_write_err, credits no
// chunks or bytes, and leaves done_flushed_us absent — the row never claims
// output the client did not receive — for every streaming variant.
func TestStreamRelay_FailedWriteMarksClientWriteErr(t *testing.T) {
	s := newRelayBenchServer()
	for _, variant := range relayVariants {
		t.Run(variant, func(t *testing.T) {
			rp := registry.NewRequestProfile(time.Now(), "coord-fail-"+variant, nil, 0)
			pr := newPrefilledBurstRequest(20, variant)
			pr.Profile = rp.NewAttempt(pr.RequestID, 1, "")
			w := &failingResponseWriter{header: make(http.Header)}
			s.handleStreamingResponseWithFirstChunkAndError(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr, nil, nil)
			if w.status != http.StatusOK {
				t.Fatalf("status = %d", w.status)
			}
			if !rp.ClientWriteErr.Load() {
				t.Fatal("client_write_err not set after a failed write")
			}
			if rp.ChunksOut.Load() != 0 || rp.BytesOut.Load() != 0 {
				t.Fatalf("credited chunks=%d bytes=%d the client never received", rp.ChunksOut.Load(), rp.BytesOut.Load())
			}
			if rp.DoneFlushedUS.Load() != 0 {
				t.Fatal("done_flushed_us stamped on a stream whose writes failed")
			}
		})
	}
}
