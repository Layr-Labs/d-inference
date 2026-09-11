package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestInputTokenFloorReasoningHistory(t *testing.T) {
	for _, field := range []string{"thinking", "reasoning", "reasoning_content", "anthropic thinking"} {
		for _, length := range []int{108, 112} {
			t.Run(fmt.Sprintf("%s/%d", field, length), func(t *testing.T) {
				h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 32}, map[string]any{"min_input_tokens": 32})
				message := map[string]any{"role": "assistant", "content": "", field: strings.Repeat("a", length)}
				endpoint := promptcontract.EndpointChatCompletions
				path := "/v1/chat/completions"
				if field == "anthropic thinking" {
					delete(message, field)
					message["content"] = []any{map[string]any{"type": "thinking", "thinking": strings.Repeat("a", length), "signature": strings.Repeat("x", 1000)}}
					endpoint = promptcontract.EndpointMessages
					path = "/v1/messages"
				}
				body := map[string]any{"model": runtimeDefaultsAlias, "messages": []any{message}, "max_tokens": 32}
				if got := inputFloorPromptTokens(body, endpoint); got != 4+length/4 {
					t.Fatalf("reasoning count=%d", got)
				}
				raw, _ := json.Marshal(body)
				if length == 112 {
					postRuntimeDefaultsEndpoint(t, h, path, string(raw))
					forwarded := readRuntimeDefaultsProviderBody(t, h.providers[0])
					if !strings.Contains(string(forwarded["messages"]), strings.Repeat("a", length)) {
						t.Fatal("reasoning was not forwarded")
					}
				} else {
					req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(string(raw)))
					req.Header.Set("Authorization", "Bearer test-key")
					w := httptest.NewRecorder()
					h.coordinator.Handler().ServeHTTP(w, req)
					if w.Code != 400 || !strings.Contains(w.Body.String(), "estimated 31 input tokens") {
						t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
					}
				}
			})
		}
	}
	// Alternative spellings are one reasoning channel, not cumulative padding.
	body := map[string]any{"messages": []any{map[string]any{"role": "assistant", "content": "", "thinking": "hi", "reasoning": strings.Repeat("x", 1000), "reasoning_content": strings.Repeat("x", 1000)}}}
	if got := inputFloorPromptTokens(body, promptcontract.EndpointChatCompletions); got != 5 {
		t.Fatalf("duplicate reasoning fields padded floor: %d", got)
	}
}

func TestInputTokenFloorNativeCompletionBatch(t *testing.T) {
	for _, tc := range []struct {
		name     string
		prompts  []any
		want     int
		accepted bool
	}{
		{"eight empty prompts", []any{"", "", "", "", "", "", "", ""}, 0, false},
		{"empty token batches", []any{[]any{}, []any{}}, 0, false},
		{"batch below floor", []any{strings.Repeat("a", 60), strings.Repeat("b", 64)}, 31, false},
		{"batch at floor", []any{strings.Repeat("a", 64), strings.Repeat("b", 64)}, 32, true},
		{"single prompt keeps framing", []any{strings.Repeat("a", 112)}, 32, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 32}, map[string]any{"min_input_tokens": 32})
			body := map[string]any{"model": runtimeDefaultsAlias, "prompt": tc.prompts, "max_tokens": 32}
			if got := inputFloorPromptTokens(body, promptcontract.EndpointCompletions); got != tc.want {
				t.Fatalf("floor=%d want=%d", got, tc.want)
			}
			raw, _ := json.Marshal(body)
			if tc.accepted {
				postRuntimeDefaultsEndpoint(t, h, "/v1/completions", string(raw))
				forwarded := readRuntimeDefaultsProviderBody(t, h.providers[0])
				if len(tc.prompts) > 1 && len(forwarded["prompt"]) == 0 {
					t.Fatal("batch lost native forwarding")
				}
			} else {
				req := httptest.NewRequest(http.MethodPost, "/v1/completions", strings.NewReader(string(raw)))
				req.Header.Set("Authorization", "Bearer test-key")
				w := httptest.NewRecorder()
				h.coordinator.Handler().ServeHTTP(w, req)
				if w.Code != 400 || !strings.Contains(w.Body.String(), "input_too_short") {
					t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
				}
			}
		})
	}
}
