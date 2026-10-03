package api

import (
	"net/http/httptest"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestGenericResponseMetadataPreservesCallerEndpoint(t *testing.T) {
	endpoint, stops := inreq.GenericResponseMetadata(inreq.MessagesEndpoint, map[string]any{
		"stop_sequences": []any{"<END>"},
	})
	if endpoint != inreq.MessagesEndpoint {
		t.Fatalf("endpoint = %q, want %q", endpoint, inreq.MessagesEndpoint)
	}
	if len(stops) != 1 || stops[0] != "<END>" {
		t.Fatalf("stop sequences = %v, want [<END>]", stops)
	}

	endpoint, stops = inreq.GenericResponseMetadata(inreq.CompletionsEndpoint, map[string]any{})
	if endpoint != inreq.CompletionsEndpoint || stops != nil {
		t.Fatalf("completions metadata = (%q, %v)", endpoint, stops)
	}
}

func TestMessagesStopSequenceRequiresCallerAllowlist(t *testing.T) {
	requested := []string{"<END>"}
	if got := inresp.AllowedMatchedStopSequence(requested, "<FORGED>"); got != "" {
		t.Fatalf("accepted unrequested provider stop sequence %q", got)
	}
	if got := inresp.AllowedMatchedStopSequence(requested, "<END>"); got != "<END>" {
		t.Fatalf("rejected requested provider stop sequence: %q", got)
	}
}

func TestGenericEndpointStreamEmittersUseNativeSchemas(t *testing.T) {
	t.Run("completions corrects max token finish", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		pr := &registry.PendingRequest{
			RequestID:          "request-id",
			PublicModel:        "public-model",
			ConsumerEndpoint:   inreq.CompletionsEndpoint,
			RequestedMaxTokens: 2,
		}
		emitter := inresp.NewGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.Start()
		emitter.HandleChunk(`data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}`)
		emitter.HandleChunk(`data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`)
		emitter.Finish(protocol.UsageInfo{CompletionTokens: 2})

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
			ConsumerEndpoint: inreq.MessagesEndpoint,
		}
		emitter := inresp.NewGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.Start()
		emitter.HandleChunk(`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}}]},"finish_reason":"tool_calls"}]}`)
		emitter.Finish(protocol.UsageInfo{CompletionTokens: 4})

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
			ConsumerEndpoint: inreq.MessagesEndpoint,
		}
		emitter := inresp.NewGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.Start()
		emitter.HandleChunk(`data: {"choices":[{"index":0,"delta":{"tool_calls":[` +
			`{"index":0,"id":"call-weather","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}},` +
			`{"index":0,"id":"call-time","function":{"name":"time","arguments":"{\"zone\":\"UTC\"}"}}` +
			`]},"finish_reason":"tool_calls"}]}`)
		emitter.Finish(protocol.UsageInfo{})

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

	t.Run("messages committed error uses native envelope", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		pr := &registry.PendingRequest{
			RequestID:        "request-id",
			PublicModel:      "public-model",
			ConsumerEndpoint: inreq.MessagesEndpoint,
		}
		emitter := inresp.NewGenericEndpointStreamEmitter(recorder, recorder, pr)
		emitter.Start()
		emitter.HandleChunk(
			`data: {"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}`)
		emitter.EmitError("provider_error", "generation failed")

		body := recorder.Body.String()
		if !strings.Contains(body, "event: error") ||
			!strings.Contains(body, `"type":"error"`) ||
			!strings.Contains(body, `"error":{"message":"generation failed","type":"api_error"}`) {
			t.Fatalf("messages stream did not emit native Anthropic error envelope: %s", body)
		}
		if strings.Contains(body, `"object":"error"`) ||
			strings.Contains(body, "data: [DONE]") {
			t.Fatalf("messages stream leaked OpenAI terminal framing: %s", body)
		}

		timeoutRecorder := httptest.NewRecorder()
		timeoutEmitter := inresp.NewGenericEndpointStreamEmitter(timeoutRecorder, timeoutRecorder, pr)
		timeoutEmitter.EmitError("timeout", "request timed out")
		if body := timeoutRecorder.Body.String(); !strings.Contains(
			body, `"error":{"message":"request timed out","type":"overloaded_error"}`) {
			t.Fatalf("messages stream timeout did not use Anthropic error type: %s", body)
		}
	})
}

// The terminal stream events carry the same usage breakdown as the non-stream
// responses, so a streamed caller can reconcile a cache-read discount.
func TestGenericEndpointStreamsReportCachedTokens(t *testing.T) {
	hit := protocol.UsageInfo{PromptTokens: 10_000, CachedTokens: 8_000, CompletionTokens: 500}
	for _, tc := range []struct {
		endpoint string
		want     []string
	}{
		{inreq.CompletionsEndpoint, []string{`"usage":{`, `"prompt_tokens":10000`, `"prompt_tokens_details":{"cached_tokens":8000}`, `"total_tokens":10500`}},
		{inreq.MessagesEndpoint, []string{"event: message_delta", `"input_tokens":2000`, `"cache_read_input_tokens":8000`, `"output_tokens":500`}},
	} {
		t.Run(tc.endpoint, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			pr := &registry.PendingRequest{RequestID: "request-id", PublicModel: "public-model", ConsumerEndpoint: tc.endpoint}
			emitter := inresp.NewGenericEndpointStreamEmitter(recorder, recorder, pr)
			emitter.Start()
			emitter.HandleChunk(`data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}`)
			emitter.Finish(hit)
			body := recorder.Body.String()
			for _, want := range tc.want {
				if !strings.Contains(body, want) {
					t.Errorf("stream missing %q:\n%s", want, body)
				}
			}
		})
	}
}
