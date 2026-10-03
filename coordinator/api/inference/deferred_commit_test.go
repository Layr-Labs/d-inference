package inference

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// TestStreamingFirstChunksEmittedInOrder verifies the held-preamble plumbing:
// every element of firstChunks is written in order ahead of the relay loop,
// with the single-chunk special-casing ([DONE] swallowing, normalization)
// applied per element, and exactly one coordinator-emitted [DONE] terminator.
func TestStreamingFirstChunksEmittedInOrder(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:  "first-chunks-order",
		Model:      "m",
		ChunkCh:    make(chan registry.ProviderChunk, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
	}
	close(pr.ChunkCh) // stream already complete; only firstChunks to write

	roleChunk := `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
	contentChunk := `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}`

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunkAndError(rec, req, pr, []string{roleChunk, "data: [DONE]", contentChunk}, nil)

	body := rec.Body.String()
	roleIdx := strings.Index(body, `"role":"assistant"`)
	contentIdx := strings.Index(body, `"content":"hello"`)
	if roleIdx < 0 || contentIdx < 0 {
		t.Fatalf("body missing held role chunk or content chunk:\n%s", body)
	}
	if roleIdx > contentIdx {
		t.Errorf("held role chunk must precede the committing content chunk; body:\n%s", body)
	}
	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Errorf("[DONE] count = %d, want exactly 1 (provider terminators swallowed); body:\n%s", got, body)
	}
	if strings.Contains(body, `"error"`) {
		t.Errorf("clean stream must not contain an error event; body:\n%s", body)
	}
}

func newDeferredCommitTestServer(t *testing.T) *Owner {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	return newComposedServer(reg, st, TestServerConfig{}, logger)
}
