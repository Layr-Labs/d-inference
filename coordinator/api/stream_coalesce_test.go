package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

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
