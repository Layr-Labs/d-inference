package response_test

import (
	"net/http/httptest"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/response"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestBuildMessagesResponseConvertsToolCalls(t *testing.T) {
	pr := &registry.PendingRequest{
		RequestID:        "request-id",
		PublicModel:      "public-model",
		ConsumerEndpoint: inreq.MessagesEndpoint,
	}
	message := production.ExtractedMessage{
		FinishReason: "tool_calls",
		ToolCalls: []map[string]any{{
			"id": "call-1",
			"function": map[string]any{
				"name":      "weather",
				"arguments": `{"city":"SF"}`,
			},
		}},
	}

	response := messagesResponse(pr, message, protocol.UsageInfo{
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
	message := production.ExtractMessage([]string{`data: {"choices":[{"message":{"tool_calls":[` +
		`{"index":0,"id":"call-weather","type":"function","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}},` +
		`{"index":0,"id":"call-time","type":"function","function":{"name":"time","arguments":"{\"zone\":\"UTC\"}"}}` +
		`]},"finish_reason":"tool_calls"}]}`})
	if len(message.ToolCalls) != 2 {
		t.Fatalf("reconstructed tool calls = %#v, want two logical calls", message.ToolCalls)
	}
	response := messagesResponse(&registry.PendingRequest{
		RequestID:        "request-id",
		PublicModel:      "gemma-4-26b",
		ConsumerEndpoint: inreq.MessagesEndpoint,
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
		ConsumerEndpoint:       inreq.MessagesEndpoint,
		RequestedStopSequences: []string{"<END>", "<ALT>"},
		MatchedStopSequence:    "<ALT>",
		RequestedMaxTokens:     1,
	}

	response := messagesResponse(
		pr,
		production.ExtractedMessage{Content: "answer", FinishReason: "length"},
		protocol.UsageInfo{CompletionTokens: 1},
	)
	if response["stop_reason"] != "stop_sequence" || response["stop_sequence"] != "<ALT>" {
		t.Fatalf("non-streaming stop outcome = %#v", response)
	}

	recorder := httptest.NewRecorder()
	emitter := production.NewGenericEndpointStreamEmitter(recorder, recorder, pr)
	emitter.Start()
	emitter.HandleChunk(`data: {"choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":"length"}]}`)
	emitter.Finish(protocol.UsageInfo{CompletionTokens: 1})
	body := recorder.Body.String()
	if !strings.Contains(body, `"stop_reason":"stop_sequence"`) ||
		!strings.Contains(body, `"stop_sequence":"\u003cALT\u003e"`) {
		t.Fatalf("streaming response lost matched stop sequence:\n%s", body)
	}
}

// A validated cache hit is reported the way each endpoint's own schema bills
// it, so a caller can reconcile the charge: OpenAI completions nest
// cached_tokens under prompt_tokens (a subset), Anthropic messages split the
// cache read out of input_tokens.
func TestGenericEndpointResponsesReportCachedTokens(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "request-id", PublicModel: "public-model"}
	hit := protocol.UsageInfo{PromptTokens: 10_000, CachedTokens: 8_000, CompletionTokens: 500}

	completions := completionsResponse(pr, production.ExtractedMessage{Content: "ok"}, hit)["usage"].(map[string]any)
	details, ok := completions["prompt_tokens_details"].(map[string]any)
	if completions["prompt_tokens"] != 10_000 || completions["total_tokens"] != 10_500 || !ok || details["cached_tokens"] != 8_000 {
		t.Fatalf("completions usage = %#v", completions)
	}
	messages := messagesResponse(pr, production.ExtractedMessage{Content: "ok"}, hit)["usage"].(map[string]any)
	if messages["input_tokens"] != 2_000 || messages["cache_read_input_tokens"] != 8_000 || messages["output_tokens"] != 500 {
		t.Fatalf("messages usage = %#v", messages)
	}

	miss := protocol.UsageInfo{PromptTokens: 10_000, CompletionTokens: 500}
	if u := completionsResponse(pr, production.ExtractedMessage{}, miss)["usage"].(map[string]any); u["prompt_tokens_details"] != nil {
		t.Fatalf("miss completions usage carries details: %#v", u)
	}
	if u := messagesResponse(pr, production.ExtractedMessage{}, miss)["usage"].(map[string]any); u["input_tokens"] != 10_000 || u["cache_read_input_tokens"] != nil {
		t.Fatalf("miss messages usage = %#v", u)
	}
}
