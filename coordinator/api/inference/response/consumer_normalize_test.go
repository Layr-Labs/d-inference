package response

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNormalizeSSEChunk(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantChecks func(t *testing.T, got string)
	}{
		{
			name:  "null content becomes empty string",
			input: `data: {"choices":[{"delta":{"content":null}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"content":""`) {
					t.Errorf("expected content to be empty string, got: %s", got)
				}
			},
		},
		{
			name:  "null tool_calls becomes empty array",
			input: `data: {"choices":[{"delta":{"content":"hi","tool_calls":null}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"tool_calls":[]`) {
					t.Errorf("expected tool_calls to be empty array, got: %s", got)
				}
			},
		},
		{
			name:  "usage null is removed entirely",
			input: `data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":null,"reasoning":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null}`,
			wantChecks: func(t *testing.T, got string) {
				if strings.Contains(got, `"usage"`) {
					t.Errorf("expected usage to be removed, got: %s", got)
				}
				if !strings.Contains(got, `"content":""`) {
					t.Errorf("expected content to be empty string, got: %s", got)
				}
				if !strings.Contains(got, `"reasoning":""`) {
					t.Errorf("expected reasoning to be empty string, got: %s", got)
				}
				if !strings.Contains(got, `"tool_calls":[]`) {
					t.Errorf("expected tool_calls to be empty array, got: %s", got)
				}
				// Both reasoning and reasoning_content should be present:
				// reasoning_content for AI SDK compatibility, reasoning
				// for ForgeCode and other clients.
				if !strings.Contains(got, `"reasoning_content"`) {
					t.Errorf("expected reasoning_content to be preserved for AI SDK, got: %s", got)
				}
			},
		},
		{
			name:  "no nulls returns unchanged",
			input: `data: {"choices":[{"delta":{"content":"hello"}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if got != `data: {"choices":[{"delta":{"content":"hello"}}]}` {
					t.Errorf("expected unchanged, got: %s", got)
				}
			},
		},
		{
			name:  "valid usage object is preserved",
			input: `data: {"id":"1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"prompt_tokens"`) {
					t.Errorf("expected usage to be preserved, got: %s", got)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeSSEChunk(tt.input)
			tt.wantChecks(t, got)
		})
	}
}

func TestNormalizeSSEChunkReasoningDetails(t *testing.T) {
	parseDelta := func(t *testing.T, chunk string, choice int) map[string]any {
		t.Helper()
		var payload map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(normalizeSSEChunk(chunk), "data: ")), &payload); err != nil {
			t.Fatalf("unmarshal normalized chunk: %v", err)
		}
		choices := payload["choices"].([]any)
		return choices[choice].(map[string]any)["delta"].(map[string]any)
	}
	assertCanonical := func(t *testing.T, delta map[string]any, text, id string) {
		t.Helper()
		details, ok := delta["reasoning_details"].([]any)
		if !ok || len(details) != 1 {
			t.Fatalf("reasoning_details = %#v, want one detail", delta["reasoning_details"])
		}
		detail := details[0].(map[string]any)
		if detail["type"] != "reasoning.text" || detail["text"] != text || detail["id"] != id || detail["format"] != "unknown" || detail["index"] != float64(0) || detail["signature"] != nil {
			t.Fatalf("reasoning detail = %#v", detail)
		}
	}

	t.Run("reasoning content alias gets canonical detail", func(t *testing.T) {
		delta := parseDelta(t, `data: {"choices":[{"index":3,"delta":{"reasoning_content":"thinking"}}]}`, 0)
		if delta["reasoning"] != "thinking" || delta["reasoning_content"] != "thinking" {
			t.Fatalf("reasoning aliases not synchronized: %#v", delta)
		}
		assertCanonical(t, delta, "thinking", "reasoning-text-3")
	})

	t.Run("reasoning content wins conflicting aliases", func(t *testing.T) {
		delta := parseDelta(t, `data: {"choices":[{"index":5,"delta":{"reasoning":"legacy","reasoning_content":"canonical"}}]}`, 0)
		if delta["reasoning"] != "canonical" || delta["reasoning_content"] != "canonical" {
			t.Fatalf("reasoning_content did not win alias conflict: %#v", delta)
		}
		assertCanonical(t, delta, "canonical", "reasoning-text-5")
	})

	t.Run("malformed aliases are forced to raw equality", func(t *testing.T) {
		delta := parseDelta(t, `data: {"choices":[{"index":0,"delta":{"reasoning":{"unexpected":true},"reasoning_content":["opaque"]}}]}`, 0)
		reasoning, err := json.Marshal(delta["reasoning"])
		if err != nil {
			t.Fatalf("marshal reasoning alias: %v", err)
		}
		reasoningContent, err := json.Marshal(delta["reasoning_content"])
		if err != nil {
			t.Fatalf("marshal reasoning_content alias: %v", err)
		}
		if string(reasoning) != string(reasoningContent) || string(reasoning) != `["opaque"]` {
			t.Fatalf("malformed aliases differ: reasoning=%s reasoning_content=%s", reasoning, reasoningContent)
		}
		if _, ok := delta["reasoning_details"]; ok {
			t.Fatalf("malformed reasoning created details: %#v", delta)
		}
	})

	t.Run("invalid indexes fall back to distinct choice positions", func(t *testing.T) {
		chunk := `data: {"choices":[{"index":-1,"delta":{"reasoning":"a"}},{"index":"9","delta":{"reasoning":"b"}},{"index":1.5,"delta":{"reasoning":"c"}}]}`
		for choice, wantID := range []string{"reasoning-text-0", "reasoning-text-1", "reasoning-text-2"} {
			delta := parseDelta(t, chunk, choice)
			assertCanonical(t, delta, string(rune('a'+choice)), wantID)
		}
	})

	t.Run("stable IDs across chunks and choices", func(t *testing.T) {
		first := parseDelta(t, `data: {"choices":[{"index":2,"delta":{"reasoning":"a"}},{"index":7,"delta":{"reasoning":"b"}}]}`, 0)
		second := parseDelta(t, `data: {"choices":[{"index":2,"delta":{"reasoning":"c"}},{"index":7,"delta":{"reasoning":"d"}}]}`, 0)
		other := parseDelta(t, `data: {"choices":[{"index":2,"delta":{"reasoning":"a"}},{"index":7,"delta":{"reasoning":"b"}}]}`, 1)
		assertCanonical(t, first, "a", "reasoning-text-2")
		assertCanonical(t, second, "c", "reasoning-text-2")
		assertCanonical(t, other, "b", "reasoning-text-7")
	})

	t.Run("existing details are preserved", func(t *testing.T) {
		delta := parseDelta(t, `data: {"choices":[{"index":0,"delta":{"reasoning":"thinking","reasoning_details":[{"type":"provider.custom","data":{"opaque":true}}]}}]}`, 0)
		details := delta["reasoning_details"].([]any)
		detail := details[0].(map[string]any)
		if len(details) != 1 || detail["type"] != "provider.custom" || detail["data"].(map[string]any)["opaque"] != true {
			t.Fatalf("existing reasoning_details changed: %#v", details)
		}
	})

	t.Run("empty reasoning synchronizes aliases without details", func(t *testing.T) {
		for _, chunk := range []string{
			`data: {"choices":[{"index":0,"delta":{"reasoning":""}}]}`,
			`data: {"choices":[{"index":0,"delta":{"reasoning_content":null}}]}`,
		} {
			delta := parseDelta(t, chunk, 0)
			if delta["reasoning"] != "" || delta["reasoning_content"] != "" {
				t.Fatalf("empty reasoning aliases not synchronized: %#v", delta)
			}
			if _, ok := delta["reasoning_details"]; ok {
				t.Fatalf("empty reasoning added details: %#v", delta)
			}
		}
	})
}

func BenchmarkNormalizeSSEChunk_NoNulls(b *testing.B) {
	b.ReportAllocs()
	// Fast path: no null fields, function should return early.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"content":"Hello world"},"finish_reason":null}]}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_WithNulls(b *testing.B) {
	b.ReportAllocs()
	// Slow path: has null content, tool_calls, reasoning_content that need fixing.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null,"system_fingerprint":null}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_Usage(b *testing.B) {
	b.ReportAllocs()
	// Final chunk with usage object (should be preserved, not removed).
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":83,"total_tokens":233}}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_ReasoningDelta(b *testing.B) {
	b.ReportAllocs()
	// Slow path: a reasoning delta must be mirrored across both aliases and
	// gain reasoning_details (the gate is not what makes this case expensive).
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"reasoning_content":"Let me think about this"},"finish_reason":null}]}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_ReasoningDetailsPassthrough(b *testing.B) {
	b.ReportAllocs()
	// Fast path: reasoning_details without either reasoning alias (and the
	// usual finish_reason:null) must be forwarded without a round-trip.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"content":"Hello","reasoning_details":[{"type":"reasoning.text","text":"t","index":0}]},"finish_reason":null}]}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}
