package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// A disconnected provider must leave both the registry and the routing pool.
func TestProviderEvictionRemovesFromRouting(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "eviction-routing-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, reg, models, pubKey)

	// Handle the initial challenge synchronously. waitForChallenge owns the only
	// reader until the registry records the response.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 3*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()

	// Set trust and verify routable.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	p := findRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("provider should be routable before disconnect")
	}
	reg.SetProviderIdle(p.ID)

	// Close the WebSocket to simulate provider disconnect.
	conn.Close(websocket.StatusNormalClosure, "test disconnect")

	// Wait for the server to process the disconnect.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool { return reg.ProviderCount() == 0 })

	// Verify provider is gone.
	if reg.ProviderCount() != 0 {
		t.Errorf("ProviderCount = %d, want 0 after disconnect", reg.ProviderCount())
	}
	if findRoutableProvider(reg, model) != nil {
		t.Error("routing should return nil after provider disconnects")
	}
}

// A realistic vllm-mlx stream normalization sequence keeps content, finish
// reasons, usage, and reasoning aliases while removing invalid null fields.
func TestSSEChunkNormalizationSequence(t *testing.T) {
	chunks := []struct {
		name  string
		input string
		check func(t *testing.T, result string)
	}{
		{
			name:  "first chunk: role with null content",
			input: `data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}],"usage":null}`,
			check: func(t *testing.T, result string) {
				if strings.Contains(result, `"usage"`) {
					t.Error("usage:null should be removed")
				}
				if !strings.Contains(result, `"content":""`) {
					t.Error("null content should become empty string")
				}
				if !strings.Contains(result, `"role":"assistant"`) {
					t.Error("role should be preserved")
				}
				// Verify the result is valid JSON after the "data: " prefix.
				jsonStr := strings.TrimPrefix(result, "data: ")
				var parsed map[string]any
				if err := json.Unmarshal([]byte(jsonStr), &parsed); err != nil {
					t.Errorf("result is not valid JSON: %v", err)
				}
			},
		},
		{
			name:  "middle chunk: actual content token",
			input: `data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, `"content":"Hello"`) {
					t.Error("content token should be preserved")
				}
				// No null content fields, so only finish_reason:null might be present.
				// The function only fixes delta-level nulls, not choice-level.
			},
		},
		{
			name:  "middle chunk: content with special characters",
			input: `data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"content":"Hello \"world\"\n"}}]}`,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, "Hello") {
					t.Error("content with special chars should be preserved")
				}
			},
		},
		{
			name:  "final chunk: finish_reason + usage object",
			input: `data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}`,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, `"finish_reason":"stop"`) {
					t.Error("finish_reason should be preserved")
				}
				if !strings.Contains(result, `"prompt_tokens"`) {
					t.Error("usage object should be preserved (not null)")
				}
				if !strings.Contains(result, `"total_tokens":15`) {
					t.Error("total_tokens should be preserved")
				}
			},
		},
		{
			name:  "DONE sentinel passes through unchanged",
			input: `data: [DONE]`,
			check: func(t *testing.T, result string) {
				if result != `data: [DONE]` {
					t.Errorf("DONE sentinel should pass through unchanged, got: %s", result)
				}
			},
		},
		{
			name:  "reasoning_content emits both reasoning and reasoning_content",
			input: `data: {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}`,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, `"reasoning_content":"thinking..."`) {
					t.Error("reasoning_content should be preserved for AI SDK compatibility")
				}
				if !strings.Contains(result, `"reasoning":"thinking..."`) {
					t.Error("reasoning alias should be added for other clients")
				}
			},
		},
		{
			name:  "both reasoning and reasoning_content are preserved",
			input: `data: {"choices":[{"delta":{"reasoning":"thought","reasoning_content":"thought"}}]}`,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, `"reasoning_content"`) {
					t.Error("reasoning_content should be preserved")
				}
				if !strings.Contains(result, `"reasoning"`) {
					t.Error("reasoning should be preserved")
				}
			},
		},
	}

	for _, tc := range chunks {
		t.Run(tc.name, func(t *testing.T) {
			result := normalizeSSEChunk(tc.input)
			tc.check(t, result)
		})
	}

	// Normalize a complete chunk sequence before reconstructing its content.
	pipelineChunks := []string{
		`data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}],"usage":null}`,
		`data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"content":"The"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"content":" answer"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"content":" is"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"content":" 42"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}`,
	}

	var normalized []string
	for _, chunk := range pipelineChunks {
		normalized = append(normalized, normalizeSSEChunk(chunk))
	}

	// Extract content from normalized chunks.
	msg := extractMessage(normalized)
	if msg.Content != "The answer is 42" {
		t.Errorf("assembled content = %q, want %q", msg.Content, "The answer is 42")
	}
}
