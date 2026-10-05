package inference_test

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// countingResponseWriter records writes and flushes without buffering the
// body (the bytes themselves are discarded; only counts matter here).
type countingResponseWriter struct {
	header  http.Header
	status  int
	writes  int
	bytes   int
	flushes int
}

func newCountingResponseWriter() *countingResponseWriter {
	return &countingResponseWriter{header: make(http.Header)}
}

func (w *countingResponseWriter) Header() http.Header { return w.header }

func (w *countingResponseWriter) WriteHeader(code int) { w.status = code }

func (w *countingResponseWriter) Write(p []byte) (int, error) {
	w.writes++
	w.bytes += len(p)
	return len(p), nil
}

func (w *countingResponseWriter) Flush() { w.flushes++ }

// newPrefilledBurstRequest builds a PendingRequest whose ChunkCh already holds
// n content chunks (plus a finish chunk) and is closed, with the completion
// usage already delivered, so the relay drains it without ever blocking.
func newPrefilledBurstRequest(n int, variant string) *registry.PendingRequest {
	pr := &registry.PendingRequest{
		RequestID:  "bench-req",
		Model:      burstTestModel,
		ChunkCh:    make(chan registry.ProviderChunk, n+8),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	switch variant {
	case "responses":
		pr.IsResponsesAPI = true
	case "completions":
		pr.ConsumerEndpoint = inreq.CompletionsEndpoint
	case "messages":
		pr.ConsumerEndpoint = inreq.MessagesEndpoint
	}
	for i := 0; i < n; i++ {
		pr.ChunkCh <- registry.ProviderChunk{Data: chatContentChunk("b" + strconv.Itoa(i))}
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: chatFinishChunk("stop")}
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: n}
	close(pr.CompleteCh)
	return pr
}

func newRelayBenchServer() *serverFixture {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	return newComposedServer(registry.New(logger), st, TestServerConfig{}, logger)
}

var relayVariants = []string{"chat", "responses", "completions", "messages"}

// relayBurstCounts runs one prefilled 200-chunk burst through the relay and
// returns the writer's counters.
func relayBurstCounts(s *serverFixture, n int, variant string) *countingResponseWriter {
	w := newCountingResponseWriter()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(context.Background())
	pr := newPrefilledBurstRequest(n, variant)
	s.NewRelay().Stream(w, r, pr, nil, nil)
	return w
}

// BenchmarkStreamRelayFlushes reports flushes/op, writes/op and bytes/op for a
// 200-chunk burst per streaming variant.
func BenchmarkStreamRelayFlushes(b *testing.B) {
	const n = 200
	s := newRelayBenchServer()
	for _, variant := range relayVariants {
		b.Run(variant, func(b *testing.B) {
			b.ReportAllocs()
			var flushes, writes, bytes int
			for i := 0; i < b.N; i++ {
				w := relayBurstCounts(s, n, variant)
				flushes += w.flushes
				writes += w.writes
				bytes += w.bytes
			}
			b.ReportMetric(float64(flushes)/float64(b.N), "flushes/op")
			b.ReportMetric(float64(writes)/float64(b.N), "writes/op")
			b.ReportMetric(float64(bytes)/float64(b.N), "bytes/op")
		})
	}
}
