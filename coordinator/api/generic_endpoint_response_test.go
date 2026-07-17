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

func TestBuildMessagesResponsePreservesParallelNonStreamingToolCalls(t *testing.T) {
	message := extractMessage([]string{`data: {"choices":[{"message":{"tool_calls":[` +
		`{"index":0,"id":"call-weather","type":"function","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}},` +
		`{"index":0,"id":"call-time","type":"function","function":{"name":"time","arguments":"{\"zone\":\"UTC\"}"}}` +
		`]},"finish_reason":"tool_calls"}]}`})
	if len(message.ToolCalls) != 2 {
		t.Fatalf("reconstructed tool calls = %#v, want two logical calls", message.ToolCalls)
	}
	response := buildMessagesResponse(&registry.PendingRequest{
		RequestID:        "request-id",
		PublicModel:      "gemma-4-26b",
		ConsumerEndpoint: messagesEndpoint,
	}, message, protocol.UsageInfo{})
	content, ok := response["content"].([]any)
	if !ok || len(content) != 2 {
		t.Fatalf("content = %#v, want two Anthropic tool_use blocks", response["content"])
	}
	for index, want := range []struct {
		id   string
		name string
	}{
		{id: "call-weather", name: "weather"},
		{id: "call-time", name: "time"},
	} {
		block, ok := content[index].(map[string]any)
		if !ok || block["type"] != "tool_use" || block["id"] != want.id ||
			block["name"] != want.name {
			t.Fatalf("tool block %d = %#v, want id=%q name=%q",
				index, content[index], want.id, want.name)
		}
	}
}

func TestMessagesResponsesPreserveExactMatchedStopSequence(t *testing.T) {
	pr := &registry.PendingRequest{
		RequestID:              "request-id",
		PublicModel:            "public-model",
		ConsumerEndpoint:       messagesEndpoint,
		RequestedStopSequences: []string{"<END>", "<ALT>"},
		MatchedStopSequence:    "<ALT>",
		RequestedMaxTokens:     1,
	}

	response := buildMessagesResponse(
		pr,
		extractedMessage{Content: "answer", FinishReason: "length"},
		protocol.UsageInfo{CompletionTokens: 1},
	)
	if response["stop_reason"] != "stop_sequence" || response["stop_sequence"] != "<ALT>" {
		t.Fatalf("non-streaming stop outcome = %#v", response)
	}

	recorder := httptest.NewRecorder()
	emitter := newGenericEndpointStreamEmitter(recorder, recorder, pr)
	emitter.start()
	emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":"length"}]}`)
	emitter.finish(protocol.UsageInfo{CompletionTokens: 1})
	body := recorder.Body.String()
	if !strings.Contains(body, `"stop_reason":"stop_sequence"`) ||
		!strings.Contains(body, `"stop_sequence":"\u003cALT\u003e"`) {
		t.Fatalf("streaming response lost matched stop sequence:\n%s", body)
	}
}

func TestMessagesStopSequenceRequiresCallerAllowlist(t *testing.T) {
	requested := []string{"<END>"}
	if got := allowedMatchedStopSequence(requested, "<FORGED>"); got != "" {
		t.Fatalf("accepted unrequested provider stop sequence %q", got)
	}
	if got := allowedMatchedStopSequence(requested, "<END>"); got != "<END>" {
		t.Fatalf("rejected requested provider stop sequence: %q", got)
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

	t.Run("messages preserves parallel all-index-zero calls", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		pr := &registry.PendingRequest{
			RequestID:        "request-id",
			PublicModel:      "gemma-4-26b",
			ConsumerEndpoint: messagesEndpoint,
		}
		emitter := newGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.start()
		emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{"tool_calls":[` +
			`{"index":0,"id":"call-weather","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}},` +
			`{"index":0,"id":"call-time","function":{"name":"time","arguments":"{\"zone\":\"UTC\"}"}}` +
			`]},"finish_reason":"tool_calls"}]}`)
		emitter.finish(protocol.UsageInfo{})

		body := recorder.Body.String()
		if strings.Count(body, `"type":"tool_use"`) != 2 {
			t.Fatalf("stream did not preserve both logical tool calls:\n%s", body)
		}
		for _, want := range []string{
			`"id":"call-weather"`, `"name":"weather"`,
			`"id":"call-time"`, `"name":"time"`,
		} {
			if !strings.Contains(body, want) {
				t.Fatalf("stream missing %q:\n%s", want, body)
			}
		}
	})
}
