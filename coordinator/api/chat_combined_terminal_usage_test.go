package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The native provider may place usage on the finish event instead of sending
// an additional choices:[] event. Both shapes need authoritative details, but
// only the final usage event should receive them when both shapes are present.
func TestStreamingCombinedFinishUsage(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		cached, reasoning      int
		includeUsage, separate bool
	}{
		{"cache", 4096, 0, true, false},
		{"cache_and_reasoning", 4096, 8, true, false},
		{"reasoning_only", 0, 8, true, false},
		{"no_cache_or_reasoning", 0, 0, true, false},
		{"no_usage_requested", 4096, 8, false, false},
		{"separate_usage_wins", 4096, 8, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logger := quietLogger()
			srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
			t.Cleanup(srv.Close)
			pr := &registry.PendingRequest{RequestID: "internal-job", Model: "build", PublicModel: "model",
				RequestedMaxTokens: 64, ChunkCh: make(chan registry.ProviderChunk, 4),
				ErrorCh: make(chan protocol.InferenceErrorMessage, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
				SESignature: "synthetic-signature", ResponseHash: "synthetic-content-hash"}
			frame := func(choices []any, withUsage bool) registry.ProviderChunk {
				obj := map[string]any{"id": "chat-native", "created": 123, "object": "chat.completion.chunk",
					"model": "build", "choices": choices}
				if withUsage {
					obj["usage"] = map[string]any{"prompt_tokens": 4207, "completion_tokens": 64, "total_tokens": 4271,
						"prompt_tokens_details": map[string]any{"cached_tokens": 999, "audio_tokens": 3}}
				}
				raw, err := json.Marshal(obj)
				if err != nil {
					t.Fatal(err)
				}
				return registry.ProviderChunk{Data: "data: " + string(raw)}
			}
			pr.ChunkCh <- frame([]any{map[string]any{"index": 0, "delta": map[string]any{"content": "unchanged text"}, "finish_reason": nil}}, false)
			pr.ChunkCh <- frame([]any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": "length"}}, tc.includeUsage)
			if tc.separate {
				pr.ChunkCh <- frame([]any{}, true)
			}
			usage := protocol.UsageInfo{PromptTokens: 4207, CompletionTokens: 64,
				CachedTokens: tc.cached, PrefillTokensSaved: tc.cached, ReasoningTokens: tc.reasoning}
			if tc.cached > 0 {
				usage.CacheOutcome, usage.CacheTier = "hit", "ssd"
			}
			pr.CompleteCh <- usage
			close(pr.ChunkCh)
			rec := httptest.NewRecorder()
			srv.handleStreamingResponseWithFirstChunkAndError(rec,
				httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr, nil, nil)
			body := rec.Body.String()
			if strings.Contains(body, `"cached_tokens":999`) {
				t.Fatal("unvalidated provider cache detail escaped")
			}
			cachedExpected, reasoningExpected := 0, 0
			if tc.includeUsage && tc.cached > 0 {
				cachedExpected = 1
			}
			if tc.includeUsage && tc.reasoning > 0 {
				reasoningExpected = 1
			}
			if got := strings.Count(body, `"cached_tokens":4096`); got != cachedExpected {
				t.Errorf("authoritative cache detail count = %d, want %d", got, cachedExpected)
			}
			if got := strings.Count(body, `"reasoning_tokens":8`); got != reasoningExpected {
				t.Errorf("reasoning subset detail count = %d, want %d", got, reasoningExpected)
			}
			usageExpected := 0
			if tc.includeUsage {
				usageExpected++
			}
			if tc.separate {
				usageExpected++
			}
			for _, field := range []string{`"prompt_tokens":4207`, `"completion_tokens":64`, `"total_tokens":4271`, `"audio_tokens":3`} {
				if strings.Count(body, field) != usageExpected {
					t.Errorf("ordinary usage field changed or invented: %s", field)
				}
			}
			for _, field := range []string{`"content":"unchanged text"`, `"finish_reason":"length"`,
				`"se_signature":"synthetic-signature"`, `"response_hash":"synthetic-content-hash"`, "data: [DONE]"} {
				if strings.Count(body, field) != 1 {
					t.Errorf("terminal/content/signature changed or duplicated: %s", field)
				}
			}
			for _, line := range strings.Split(body, "\n") {
				if !strings.HasPrefix(line, "data: {") {
					continue
				}
				var obj map[string]any
				if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &obj); err != nil {
					t.Fatal(err)
				}
				if obj["id"] != "chat-native" || obj["created"] != float64(123) || obj["model"] != "model" {
					t.Fatal("public stream identity or alias changed")
				}
			}
		})
	}
}
