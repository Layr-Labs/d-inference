package api

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestBuildMessagesResponseConvertsToolCalls(t *testing.T) {
	pr := &registry.PendingRequest{
		RequestID:        "request-id",
		PublicModel:      "public-model",
		ConsumerEndpoint: messagesEndpoint,
	}
	message := extractedMessage{
		FinishReason: "tool_calls",
		ToolCalls: []map[string]any{{
			"id": "call-1",
			"function": map[string]any{
				"name":      "weather",
				"arguments": `{"city":"SF"}`,
			},
		}},
	}

	response := buildMessagesResponse(pr, message, protocol.UsageInfo{
		PromptTokens: 5, CompletionTokens: 3,
	})
	if response["type"] != "message" || response["stop_reason"] != "tool_use" {
		t.Fatalf("unexpected response envelope: %#v", response)
	}
	content, ok := response["content"].([]any)
	if !ok || len(content) != 1 {
		t.Fatalf("content = %#v, want one tool_use block", response["content"])
	}
	block, ok := content[0].(map[string]any)
	if !ok || block["type"] != "tool_use" || block["id"] != "call-1" ||
		block["name"] != "weather" {
		t.Fatalf("tool block = %#v", content[0])
	}
	input, ok := block["input"].(map[string]any)
	if !ok || input["city"] != "SF" {
		t.Fatalf("tool input = %#v", block["input"])
	}
}

func TestGenericEndpointStreamEmittersUseNativeSchemas(t *testing.T) {
	t.Run("completions corrects max token finish", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		pr := &registry.PendingRequest{
			RequestID:          "request-id",
			PublicModel:        "public-model",
			ConsumerEndpoint:   completionsEndpoint,
			RequestedMaxTokens: 2,
		}
		emitter := newGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.start()
		emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}`)
		emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`)
		emitter.finish(protocol.UsageInfo{CompletionTokens: 2})

		body := recorder.Body.String()
		for _, want := range []string{
			`"object":"text_completion"`,
			`"text":"ok"`,
			`"finish_reason":"length"`,
			"data: [DONE]",
		} {
			if !strings.Contains(body, want) {
				t.Errorf("stream missing %q:\n%s", want, body)
			}
		}
		if strings.Contains(body, `"delta"`) {
			t.Fatalf("completion stream leaked chat delta: %s", body)
		}
	})

	t.Run("messages emits tool use lifecycle", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		pr := &registry.PendingRequest{
			RequestID:        "request-id",
			PublicModel:      "public-model",
			ConsumerEndpoint: messagesEndpoint,
		}
		emitter := newGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.start()
		emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}}]},"finish_reason":"tool_calls"}]}`)
		emitter.finish(protocol.UsageInfo{CompletionTokens: 4})

		body := recorder.Body.String()
		for _, want := range []string{
			"event: message_start",
			`"type":"tool_use"`,
			`"type":"input_json_delta"`,
			`"partial_json":"{\"city\":\"SF\"}"`,
			`"stop_reason":"tool_use"`,
			"event: message_stop",
		} {
			if !strings.Contains(body, want) {
				t.Errorf("stream missing %q:\n%s", want, body)
			}
		}
	})
}
