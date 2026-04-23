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

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// TestIntegration_ProviderEvictionRemovesFromRouting verifies that when a
// provider's WebSocket connection closes, it is removed from the registry
// and is no longer routable via FindProvider.
func TestIntegration_ProviderEvictionRemovesFromRouting(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "eviction-routing-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)

	// Handle the initial challenge so the provider becomes routable.
	challengeDone := make(chan struct{})
	go func() {
		defer close(challengeDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-challengeDone:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for challenge")
	}
	time.Sleep(200 * time.Millisecond)

	// Set trust and verify routable.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	p := reg.FindProvider(model)
	if p == nil {
		t.Fatal("provider should be routable before disconnect")
	}
	reg.SetProviderIdle(p.ID)

	// Close the WebSocket to simulate provider disconnect.
	conn.Close(websocket.StatusNormalClosure, "test disconnect")

	// Wait for the server to process the disconnect.
	time.Sleep(500 * time.Millisecond)

	// Verify provider is gone.
	if reg.ProviderCount() != 0 {
		t.Errorf("ProviderCount = %d, want 0 after disconnect", reg.ProviderCount())
	}
	if reg.FindProvider(model) != nil {
		t.Error("FindProvider should return nil after provider disconnects")
	}
}

// TestIntegration_SSEChunkNormalization tests the normalizeSSEChunk function
// with realistic vllm-mlx output patterns covering the full lifecycle of a
// streaming response: initial role chunk, content tokens, and final chunk
// with finish_reason and usage.
func TestIntegration_SSEChunkNormalization(t *testing.T) {
	// The existing TestNormalizeSSEChunk covers basic cases. This test covers
	// the full pipeline of a realistic vllm-mlx streaming response.
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
			name:  "reasoning_content renamed to reasoning",
			input: `data: {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}`,
			check: func(t *testing.T, result string) {
				if strings.Contains(result, `"reasoning_content"`) {
					t.Error("reasoning_content should be renamed to reasoning")
				}
				if !strings.Contains(result, `"reasoning":"thinking..."`) {
					t.Error("reasoning should contain the original reasoning_content value")
				}
			},
		},
		{
			name:  "both reasoning and reasoning_content deduplicates",
			input: `data: {"choices":[{"delta":{"reasoning":"thought","reasoning_content":"thought"}}]}`,
			check: func(t *testing.T, result string) {
				if strings.Contains(result, `"reasoning_content"`) {
					t.Error("reasoning_content should be removed when reasoning is present")
				}
				if !strings.Contains(result, `"reasoning":"thought"`) {
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

	// Full pipeline test: process all chunks in sequence and verify the
	// assembled content matches expectations.
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

