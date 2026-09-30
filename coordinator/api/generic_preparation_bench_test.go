package api

// Actual generic-endpoint HTTP baseline, not another preprocessing executor.
// Timing includes HTTP, coordinator encryption/transport and response validation;
// the synthetic provider does not decrypt requests during benchmark samples.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type genericPreparationCase struct {
	name     string
	endpoint string
	body     []byte
	messages []protocol.ChatMessage
	tools    []any
}

func genericPreparationCases(tb testing.TB) []genericPreparationCase {
	tb.Helper()
	var cases []genericPreparationCase
	for _, history := range []bool{false, true} {
		name, prompt := "small", benchTurnText
		messages := []protocol.ChatMessage{{Role: "user", Content: benchTurnText}}
		if history {
			name, prompt = "history", strings.Repeat(benchTurnText, 40)
			messages = nil
			for i := 0; i < 40; i++ {
				role := "user"
				if i%2 == 1 {
					role = "assistant"
				}
				messages = append(messages, protocol.ChatMessage{Role: role, Content: benchTurnText})
			}
			messages = append(messages, protocol.ChatMessage{Role: "user", Content: "Summarize the conversation."})
		}
		completions := map[string]any{"model": benchAlias, "stream": false, "max_tokens": 64, "prompt": prompt}
		messagesBody := map[string]any{"model": benchAlias, "stream": false, "max_tokens": 64,
			"system": "You are a concise assistant.", "messages": messages}
		marshal := func(value any) []byte {
			body, err := json.Marshal(value)
			if err != nil {
				tb.Fatal(err)
			}
			return body
		}
		cases = append(cases, genericPreparationCase{name: "completions_" + name, endpoint: completionsEndpoint,
			body: marshal(completions), messages: []protocol.ChatMessage{{Role: "user", Content: prompt}}})
		wantMessages := append([]protocol.ChatMessage{{Role: "system", Content: "You are a concise assistant."}}, messages...)
		cases = append(cases, genericPreparationCase{name: "messages_" + name, endpoint: messagesEndpoint,
			body: marshal(messagesBody), messages: wantMessages})
		if history {
			var tools, loweredTools []any
			for i := 0; i < 6; i++ {
				name := fmt.Sprintf("lookup_%d", i)
				schema := map[string]any{"type": "object", "properties": map[string]any{
					"query": map[string]any{"type": "string"}, "limit": map[string]any{"type": "integer"},
				}, "required": []any{"query"}}
				tools = append(tools, map[string]any{"name": name, "description": "Look something up", "input_schema": schema})
				loweredTools = append(loweredTools, map[string]any{"type": "function", "function": map[string]any{
					"name": name, "description": "Look something up", "parameters": schema,
				}})
			}
			messagesBody["tools"], messagesBody["tool_choice"] = tools, map[string]any{"type": "auto"}
			cases = append(cases, genericPreparationCase{name: "messages_history_tools", endpoint: messagesEndpoint,
				body: marshal(messagesBody), messages: wantMessages, tools: loweredTools})
		}
	}
	if len(cases) != 5 {
		tb.Fatalf("generic HTTP matrix has %d cases, want 5", len(cases))
	}
	seen := make(map[string]bool, len(cases))
	for _, tc := range cases {
		if tc.name == "" || seen[tc.name] || len(tc.body) == 0 || len(tc.messages) == 0 ||
			(tc.endpoint != completionsEndpoint && tc.endpoint != messagesEndpoint) {
			tb.Fatal("generic HTTP matrix contains an empty, duplicate or invalid case")
		}
		seen[tc.name] = true
	}
	return cases
}

func genericPreparationPost(env *benchEnv, tc genericPreparationCase) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, env.ts.URL+tc.endpoint, bytes.NewReader(tc.body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := env.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK || len(raw) > 1<<20 {
		return fmt.Errorf("generic HTTP status=%d response_bytes=%d", resp.StatusCode, len(raw))
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		return fmt.Errorf("generic response JSON: %w", err)
	}
	id, _ := body["id"].(string)
	usage, _ := body["usage"].(map[string]any)
	if id == "" || body["model"] != benchAlias || body["error"] != nil || usage == nil {
		return fmt.Errorf("generic response missing identity/model/usage or carries error")
	}
	if tc.endpoint == completionsEndpoint {
		choices, _ := body["choices"].([]any)
		if body["object"] != "text_completion" || len(choices) != 1 {
			return fmt.Errorf("completion response has wrong schema")
		}
		choice, _ := choices[0].(map[string]any)
		if choice["text"] != "bench" || choice["finish_reason"] != "stop" || choice["message"] != nil ||
			usage["prompt_tokens"] != float64(5) || usage["completion_tokens"] != float64(1) || usage["total_tokens"] != float64(6) {
			return fmt.Errorf("completion content/finish/usage differs")
		}
	} else {
		content, _ := body["content"].([]any)
		if body["type"] != "message" || body["role"] != "assistant" || body["stop_reason"] != "end_turn" || len(content) != 1 || body["choices"] != nil {
			return fmt.Errorf("messages response has wrong schema/terminal")
		}
		block, _ := content[0].(map[string]any)
		if block["type"] != "text" || block["text"] != "bench" || usage["input_tokens"] != float64(5) || usage["output_tokens"] != float64(1) {
			return fmt.Errorf("messages content/usage differs")
		}
	}
	return nil
}

type genericPreparationObservation struct {
	request protocol.InferenceRequestMessage
	body    map[string]any
	err     error
}

func TestGenericPreparationHTTPBaseline(t *testing.T) {
	for _, tc := range genericPreparationCases(t) {
		t.Run(tc.name, func(t *testing.T) {
			observed := make(chan genericPreparationObservation, 2)
			env := newBenchEnvWithObserver(t, func(req protocol.InferenceRequestMessage, keys testProviderKeyPair) {
				observation := genericPreparationObservation{request: req}
				if req.EncryptedBody == nil {
					observation.err = fmt.Errorf("dispatch is not encrypted")
				} else {
					var raw []byte
					raw, observation.err = e2e.DecryptWithPrivateKey(&e2e.EncryptedPayload{
						EphemeralPublicKey: req.EncryptedBody.EphemeralPublicKey, Ciphertext: req.EncryptedBody.Ciphertext,
					}, keys.private)
					if observation.err == nil {
						observation.err = json.Unmarshal(raw, &observation.body)
					}
				}
				select {
				case observed <- observation:
				default:
				}
			})
			defer env.close()
			if err := genericPreparationPost(env, tc); err != nil {
				t.Fatal(err)
			}
			var got genericPreparationObservation
			select {
			case got = <-observed:
			case <-time.After(5 * time.Second):
				t.Fatal("successful HTTP response had no observed dispatch")
			}
			if got.err != nil {
				t.Fatal(got.err)
			}
			if got.request.RequestID == "" {
				t.Fatal("dispatch lacks identity")
			}
			if got.body["model"] != benchDesiredBuild || got.body["max_tokens"] != float64(64) ||
				got.body["reasoning_parser"] != "qwen3" || got.body["tool_call_parser"] != "qwen3_coder" {
				t.Fatal("forwarded model/token bound/catalog defaults differ")
			}
			for _, native := range []string{"endpoint", "prompt", "system", "stop_sequences"} {
				if _, exists := got.body[native]; exists {
					t.Fatalf("successfully lowered body retains native field %q", native)
				}
			}
			messageBytes, err := json.Marshal(got.body["messages"])
			if err != nil {
				t.Fatal(err)
			}
			var messages []protocol.ChatMessage
			if err := json.Unmarshal(messageBytes, &messages); err != nil || !reflect.DeepEqual(messages, tc.messages) {
				t.Fatal("lowered roles/content/history differ from independent fixture expectation")
			}
			if len(tc.tools) > 0 {
				if !reflect.DeepEqual(got.body["tools"], tc.tools) || got.body["tool_choice"] != "auto" {
					t.Fatal("valid Anthropic tool schemas/choice were not preserved in chat lowering")
				}
			} else if _, exists := got.body["tools"]; exists {
				t.Fatal("tool-free request unexpectedly gained tools")
			}
			select {
			case <-observed:
				t.Fatal("one baseline request produced duplicate observed dispatches")
			default:
			}
		})
	}
}

func BenchmarkGenericPreparationHTTP(b *testing.B) {
	for _, tc := range genericPreparationCases(b) {
		b.Run(tc.name, func(b *testing.B) {
			env := newBenchEnv(b)
			defer env.close()
			if err := genericPreparationPost(env, tc); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.SetBytes(int64(len(tc.body)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := genericPreparationPost(env, tc); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportMetric(float64(b.N), "verified_http_ops")
		})
	}
}
