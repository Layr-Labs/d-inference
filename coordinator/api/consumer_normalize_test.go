package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

func TestExtractMessage(t *testing.T) {
	chunks := []string{
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
	}

	msg := extractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
	if len(msg.ToolCalls) != 0 {
		t.Errorf("tool_calls = %v, want empty", msg.ToolCalls)
	}
}

func TestExtractMessageEmpty(t *testing.T) {
	msg := extractMessage(nil)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
}

func TestExtractMessageWithToolCalls(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"lo"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cation\":"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"SF\"}"}}]}}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
	if len(msg.ToolCalls) != 1 {
		t.Fatalf("tool_calls length = %d, want 1", len(msg.ToolCalls))
	}
	tc := msg.ToolCalls[0]
	if tc["id"] != "call_abc" {
		t.Errorf("tool_call id = %v, want call_abc", tc["id"])
	}
	fn := tc["function"].(map[string]any)
	if fn["name"] != "get_weather" {
		t.Errorf("function name = %v, want get_weather", fn["name"])
	}
	if fn["arguments"] != `{"location":"SF"}` {
		t.Errorf("function arguments = %v, want {\"location\":\"SF\"}", fn["arguments"])
	}
}

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

func TestNormalizeCompleteChatResponse(t *testing.T) {
	resp := map[string]any{
		"id":     "chatcmpl-1",
		"object": "chat.completion",
		"model":  "/Users/provider/.cache/huggingface/hub/models--mlx-community--MiniMax-M2.5-8bit/snapshots/main",
		"choices": []any{
			map[string]any{
				"index": 0,
				"message": map[string]any{
					"role":              "assistant",
					"content":           "<think>work through it</think>\n\n4",
					"reasoning_content": "existing reasoning",
					"tool_calls":        nil,
				},
			},
		},
		"system_fingerprint": nil,
	}

	normalizeCompleteChatResponse(resp, "mlx-community/MiniMax-M2.5-8bit")

	if resp["model"] != "mlx-community/MiniMax-M2.5-8bit" {
		t.Fatalf("model = %v", resp["model"])
	}
	if _, ok := resp["system_fingerprint"]; ok {
		t.Fatalf("system_fingerprint should be removed: %#v", resp)
	}
	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["content"] != "4" {
		t.Fatalf("content = %q, want 4", message["content"])
	}
	if _, ok := message["reasoning_content"]; ok {
		t.Fatalf("reasoning_content should be removed: %#v", message)
	}
	if _, ok := message["tool_calls"]; ok {
		t.Fatalf("null tool_calls should be removed: %#v", message)
	}
	reasoning := message["reasoning"].(string)
	if !strings.Contains(reasoning, "existing reasoning") || !strings.Contains(reasoning, "work through it") {
		t.Fatalf("reasoning was not merged correctly: %q", reasoning)
	}
}

func TestNormalizeCompleteChatResponseNullContent(t *testing.T) {
	resp := map[string]any{
		"object": "chat.completion",
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"role":    "assistant",
					"content": nil,
				},
			},
		},
	}

	normalizeCompleteChatResponse(resp, "test-model")

	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["content"] != "" {
		t.Fatalf("content = %v, want empty string", message["content"])
	}
}

func TestResponsesRequestToChatCompletions(t *testing.T) {
	req := map[string]any{
		"model":             "mlx-community/gemma-4-26b-a4b-it-8bit",
		"max_output_tokens": float64(64),
		"input": []any{
			map[string]any{
				"role": "user",
				"content": []any{
					map[string]any{"type": "input_text", "text": "Reply exactly OK"},
				},
			},
		},
		"tools": []any{
			map[string]any{
				"type":        "function",
				"name":        "get_current_weather",
				"description": "Get weather",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"city": map[string]any{"type": "string"},
					},
				},
			},
		},
		"tool_choice": map[string]any{"type": "function", "name": "get_current_weather"},
	}

	got, err := responsesRequestToChatCompletions(req)
	if err != nil {
		t.Fatalf("responsesRequestToChatCompletions: %v", err)
	}
	if _, ok := got["input"]; ok {
		t.Fatalf("input should not be forwarded to chat backend: %#v", got)
	}
	if got["max_tokens"] != 64 {
		t.Fatalf("max_tokens = %v, want 64", got["max_tokens"])
	}
	messages := got["messages"].([]map[string]any)
	if messages[0]["role"] != "user" || messages[0]["content"] != "Reply exactly OK" {
		t.Fatalf("messages = %#v", messages)
	}
	tools := got["tools"].([]any)
	firstTool := tools[0].(map[string]any)
	fn := firstTool["function"].(map[string]any)
	if firstTool["type"] != "function" || fn["name"] != "get_current_weather" {
		t.Fatalf("tools = %#v", tools)
	}
	choiceFn := got["tool_choice"].(map[string]any)["function"].(map[string]any)
	if choiceFn["name"] != "get_current_weather" {
		t.Fatalf("tool_choice = %#v", got["tool_choice"])
	}
}

func TestResponsesInputToolTranscriptToChatMessages(t *testing.T) {
	input := []any{
		map[string]any{
			"role":    "user",
			"content": []any{map[string]any{"type": "input_text", "text": "weather?"}},
		},
		map[string]any{
			"type":      "function_call",
			"call_id":   "call_123",
			"name":      "get_current_weather",
			"arguments": `{"city":"Paris"}`,
		},
		map[string]any{
			"type":    "function_call_output",
			"call_id": "call_123",
			"output":  `{"temperature":21}`,
		},
	}

	messages, err := responsesInputToChatMessages(input)
	if err != nil {
		t.Fatalf("responsesInputToChatMessages: %v", err)
	}
	if len(messages) != 3 {
		t.Fatalf("len(messages) = %d, want 3: %#v", len(messages), messages)
	}
	if messages[1]["role"] != "assistant" {
		t.Fatalf("second message = %#v", messages[1])
	}
	toolCalls := messages[1]["tool_calls"].([]map[string]any)
	if toolCalls[0]["id"] != "call_123" {
		t.Fatalf("tool_calls = %#v", toolCalls)
	}
	if messages[2]["role"] != "tool" || messages[2]["tool_call_id"] != "call_123" {
		t.Fatalf("third message = %#v", messages[2])
	}
}

func TestChatCompletionToResponses(t *testing.T) {
	chat := types.ChatCompletionResponse{
		ID:      "chatcmpl-test",
		Object:  "chat.completion",
		Created: 123,
		Model:   "local-path",
		Choices: []types.ChatCompletionChoice{{
			FinishReason: "tool_calls",
			Message: types.ChatCompletionMessage{
				Role:      "assistant",
				Content:   "",
				Reasoning: "need weather",
				ToolCalls: []map[string]any{
					{
						"id":   "call_123",
						"type": "function",
						"function": map[string]any{
							"name":      "get_current_weather",
							"arguments": `{"city":"Paris"}`,
						},
					},
				},
			},
		}},
		Usage: types.ChatCompletionUsage{
			PromptTokens:     10,
			CompletionTokens: 5,
			TotalTokens:      15,
		},
	}

	got := chatCompletionToResponses(chat, "mlx-community/gemma-4-26b-a4b-it-8bit", "", "")
	if got.Object != "response" || got.Model != "mlx-community/gemma-4-26b-a4b-it-8bit" {
		t.Fatalf("response metadata = %#v", got)
	}
	output := got.Output
	if output[0].(map[string]any)["type"] != "reasoning" {
		t.Fatalf("first output = %#v", output[0])
	}
	call := output[1].(map[string]any)
	if call["type"] != "function_call" || call["call_id"] != "call_123" {
		t.Fatalf("function call output = %#v", call)
	}
	usage := got.Usage
	if usage.InputTokens != 10 || usage.OutputTokens != 5 {
		t.Fatalf("usage = %#v", usage)
	}

	// Verify wire format preserves zero-valued fields.
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	wire := string(b)
	if !strings.Contains(wire, `"incomplete_details"`) {
		t.Errorf("wire output missing incomplete_details field: %s", wire)
	}
	if !strings.Contains(wire, `"cached_tokens"`) {
		t.Errorf("wire output missing cached_tokens in usage details: %s", wire)
	}
	if !strings.Contains(wire, `"reasoning_tokens"`) {
		t.Errorf("wire output missing reasoning_tokens in usage details: %s", wire)
	}
}

func TestExtractMessageWithNullFields(t *testing.T) {
	// Simulates real vllm-mlx chunks where the first chunk has null content
	// and subsequent chunks have actual content.
	chunks := []string{
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
}

func TestExtractMessageWithReasoningContentAndThinkTags(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}`,
		`data: {"choices":[{"delta":{"content":"<think>more hidden</think>\n\n4"}}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "4" {
		t.Fatalf("content = %q, want 4", msg.Content)
	}
	if !strings.Contains(msg.Reasoning, "hidden") || !strings.Contains(msg.Reasoning, "more hidden") {
		t.Fatalf("reasoning not preserved: %q", msg.Reasoning)
	}
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
