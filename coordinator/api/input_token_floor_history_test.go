package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestInputTokenFloorRetainsNativePrompt(t *testing.T) {
	for _, kind := range []string{"document", "future_native_part"} {
		t.Run(kind, func(t *testing.T) {
			h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 32}, map[string]any{"min_input_tokens": 32})
			body := map[string]any{"model": runtimeDefaultsAlias, "max_tokens": 32, "messages": []any{map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": strings.Repeat("a", 128)},
				map[string]any{"type": kind, "source": map[string]any{"type": "text", "data": "small attachment"}},
			}}}}
			raw, _ := json.Marshal(body)
			if _, err := promptcontract.LowerProviderBody(promptcontract.EndpointMessages, raw); err == nil {
				t.Fatal("fixture must use native forwarding")
			}
			if got := inputFloorPromptTokens(body, promptcontract.EndpointMessages); got < 32 {
				t.Fatalf("native prompt discarded: %d", got)
			}
			postRuntimeDefaultsEndpoint(t, h, "/v1/messages", string(raw))
			forwarded := readRuntimeDefaultsProviderBody(t, h.providers[0])
			if !strings.Contains(string(forwarded["messages"]), kind) {
				t.Fatal("native attachment was removed")
			}
		})
	}
}

func TestInputTokenFloorCountsToolHistory(t *testing.T) {
	arguments := `{"query":"` + strings.Repeat("a", 128) + `"}`
	function := map[string]any{"name": "search", "arguments": arguments}
	for _, tc := range []struct {
		name, path string
		endpoint   promptcontract.Endpoint
		body       map[string]any
	}{
		{"chat", "/v1/chat/completions", promptcontract.EndpointChatCompletions, map[string]any{"messages": []any{map[string]any{"role": "assistant", "content": "", "tool_calls": []any{map[string]any{"id": "c1", "type": "function", "function": function}}}}}},
		{"responses", "/v1/responses", promptcontract.EndpointResponses, map[string]any{"input": []any{map[string]any{"type": "function_call", "call_id": "c1", "name": "search", "arguments": arguments}}}},
		{"anthropic", "/v1/messages", promptcontract.EndpointMessages, map[string]any{"messages": []any{map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "tool_use", "id": "c1", "name": "search", "input": map[string]any{"query": strings.Repeat("a", 128)}}}}}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 32}, map[string]any{"min_input_tokens": 32})
			tc.body["model"] = runtimeDefaultsAlias
			tc.body["max_tokens"] = 32
			raw, _ := json.Marshal(tc.body)
			lowered, err := promptcontract.LowerProviderBody(tc.endpoint, raw)
			if err != nil {
				t.Fatal(err)
			}
			canonical, err := decodeInferenceJSONObject(lowered)
			if err != nil {
				t.Fatal(err)
			}
			want := 4 + textPromptTokens("search") + textPromptTokens(arguments)
			if got := inputFloorPromptTokens(tc.body, tc.endpoint); got != want || got != inputFloorMessageTokens(canonical["messages"]) {
				t.Fatalf("tool history floor=%d want=%d", got, want)
			}
			postRuntimeDefaultsEndpoint(t, h, tc.path, string(raw))
			forwarded := readRuntimeDefaultsProviderBody(t, h.providers[0])
			if !strings.Contains(string(forwarded["messages"]), strings.Repeat("a", 128)) {
				t.Fatal("tool arguments did not reach provider")
			}
		})
	}
	// Wrapper metadata is not function content and cannot pad a short call.
	messages := []any{map[string]any{"role": "assistant", "content": "", "tool_calls": []any{map[string]any{"id": strings.Repeat("x", 10000), "type": "function", "function": map[string]any{"name": "f", "arguments": "{}", "metadata": strings.Repeat("x", 10000)}}}}}
	if got := inputFloorMessageTokens(messages); got != 6 {
		t.Fatalf("metadata inflated tool call: %d", got)
	}
}
