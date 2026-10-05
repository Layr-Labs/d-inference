package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestStreamingChatMissingCompletionUsesBoundedFallback(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		logger := quietLogger()
		srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
		defer srv.Close()
		pr := &registry.PendingRequest{
			RequestID: "missing-completion", Model: "test-model",
			ChunkCh:    make(chan registry.ProviderChunk, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
		}
		pr.ChunkCh <- registry.ProviderChunk{Data: `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`}
		close(pr.ChunkCh)
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
		started := time.Now()
		srv.NewRelay().Stream(recorder, request, pr, nil, nil)
		if elapsed := time.Since(started); elapsed != 2*time.Second {
			t.Fatalf("missing completion fallback took %s, want 2s", elapsed)
		}
		body := recorder.Body.String()
		if !strings.Contains(body, `"finish_reason":"stop"`) || strings.Count(body, "data: [DONE]") != 1 ||
			!strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
			t.Fatalf("fallback must preserve finish frame and terminate once: %s", body)
		}
	})
}
