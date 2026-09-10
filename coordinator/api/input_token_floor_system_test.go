package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestInputTokenFloorAnthropicSystemMatchesLowering(t *testing.T) {
	for _, system := range []any{
		strings.Repeat("a", 92),
		[]any{map[string]any{"type": "text", "text": strings.Repeat("a", 45)}, map[string]any{"type": "text", "text": strings.Repeat("b", 46), "cache_control": map[string]any{"ignored": strings.Repeat("x", 1000)}}},
		"", nil,
		[]any{map[string]any{"type": "unknown", "text": strings.Repeat("a", 1000)}},
	} {
		parsed := map[string]any{"model": "m", "messages": []any{map[string]any{"role": "user", "content": "hi"}}, "system": system}
		raw, _ := json.Marshal(parsed)
		lowered, err := promptcontract.LowerProviderBody(promptcontract.EndpointMessages, raw)
		if err != nil {
			t.Fatal(err)
		}
		body, err := decodeInferenceJSONObject(lowered)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := routingShape(body)
		if got := inputFloorPromptTokens(parsed, promptcontract.EndpointMessages); got != want {
			t.Fatalf("floor=%d lowered=%d", got, want)
		}
		native, _ := routingShape(parsed)
		for _, endpoint := range []promptcontract.Endpoint{promptcontract.EndpointChatCompletions, promptcontract.EndpointCompletions, promptcontract.EndpointResponses} {
			want := 0 // These bodies have no active prompt/input on the other endpoints.
			if endpoint == promptcontract.EndpointChatCompletions {
				want = native
			}
			if got := inputFloorPromptTokens(parsed, endpoint); got != want {
				t.Fatalf("endpoint %s: floor=%d want=%d", endpoint, got, want)
			}
		}
	}
}

func TestInputTokenFloorAnthropicSystemBoundary(t *testing.T) {
	for _, format := range []string{"string", "blocks"} {
		for _, length := range []int{88, 92} {
			t.Run(format+"/"+map[int]string{88: "below", 92: "at"}[length], func(t *testing.T) {
				h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 0}, map[string]any{"min_input_tokens": 32})
				system := any(strings.Repeat("s", length))
				if format == "blocks" {
					system = []any{map[string]any{"type": "text", "text": strings.Repeat("s", length), "cache_control": map[string]any{"type": "ephemeral"}}}
				}
				parsed := map[string]any{"model": runtimeDefaultsAlias, "messages": []any{map[string]any{"role": "user", "content": "hi"}}, "system": system, "max_tokens": 32, "stream": true}
				raw, _ := json.Marshal(parsed)
				req, err := http.NewRequestWithContext(h.ctx, http.MethodPost, h.server.URL+"/v1/messages", strings.NewReader(string(raw)))
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("Authorization", "Bearer test-key")
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				response, err := io.ReadAll(resp.Body)
				resp.Body.Close()
				if err != nil {
					t.Fatal(err)
				}
				if length == 88 {
					if resp.StatusCode != 400 || !strings.Contains(string(response), "estimated 31 input tokens") {
						t.Fatalf("status=%d body=%s", resp.StatusCode, response)
					}
				} else {
					if resp.StatusCode != 200 {
						t.Fatalf("status=%d body=%s", resp.StatusCode, response)
					}
					readRuntimeDefaultsProviderBody(t, h.providers[0])
				}
			})
		}
	}
}
