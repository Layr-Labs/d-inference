package api

import (
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
