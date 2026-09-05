package api

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAccountingChunkContentEvidence(t *testing.T) {
	for _, tc := range []struct {
		name, chunk string
		want        bool
	}{
		{"done", "data: [DONE]", false},
		{"role", `data: {"choices":[{"delta":{"role":"assistant","content":""}}]}`, false},
		{"finish", `data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`, false},
		{"usage", `data: {"choices":[],"usage":{"completion_tokens":12}}`, false},
		{"error", `data: {"type":"error","message":"failure","text":"failure"}`, false},
		{"metadata", `data: {"metadata":{"content":"diagnostic"},"id":"output-id"}`, false},
		{"invalid", `data: {"choices":`, false},
		{"text", `data: {"choices":[{"delta":{"content":"answer"}}]}`, true},
		{"reasoning", `data: {"choices":[{"delta":{"reasoning_content":"thought"}}]}`, true},
		{"reasoning details", `data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"thought"}]}}]}`, true},
		{"opaque reasoning details", `data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"opaque","signature":"sig"}]}}]}`, false},
		{"tool name", `data: {"choices":[{"delta":{"tool_calls":[{"id":"call-id","function":{"name":"clock"}}]}}]}`, true},
		{"tool ID only", `data: {"choices":[{"delta":{"tool_calls":[{"id":"call-id","function":{}}]}}]}`, false},
		{"responses reasoning", `event: response.reasoning_summary_text.delta` + "\n" + `data: {"type":"response.reasoning_summary_text.delta","delta":"thought"}`, true},
		{"responses empty lifecycle", `data: {"type":"response.completed","response":{"output":[]}}`, false},
		{"responses failed", `data: {"type":"response.failed","response":{"error":{"message":"failure"}}}`, false},
		{"multiple events", "data: [DONE]\n\nevent: chunk\ndata:{\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n", true},
		{"bare JSON", `{"choices":[{"message":{"content":"answer"}}]}`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := accountingChunkHasContent(tc.chunk); got != tc.want {
				t.Fatalf("content=%t, want %t", got, tc.want)
			}
		})
	}
}

func contentAccountingRequest(endpoint string) (*outcomes.Tracker, *registry.PendingRequest) {
	tracker := outcomes.New("content-request", endpoint, time.Now(), nil)
	pr := &registry.PendingRequest{
		RequestID: "content-attempt", Model: "content-model", ConsumerEndpoint: endpoint,
		Accounting: tracker.NewAttempt("content-attempt", 1, ""),
	}
	return tracker, pr
}

func TestAccountingChatTerminalOnlyIsNotContent(t *testing.T) {
	tracker, pr := contentAccountingRequest("/v1/chat/completions")
	w := httptest.NewRecorder()
	stamps := newRelayStamps(nil, tracker)
	relay := newChatStreamRelay(pr, w, w, stamps)
	for _, frame := range []string{
		`data: {"choices":[{"delta":{"role":"assistant","content":""}}]}`,
		`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`,
		`data: {"choices":[],"usage":{"completion_tokens":0}}`,
		"data: [DONE]",
	} {
		relay.writeFrame(frame)
	}
	relay.flush()
	stamps.done()
	if !strings.Contains(w.Body.String(), "[DONE]") {
		t.Fatal("terminal bytes were not written")
	}
	row := tracker.Snapshot()
	if row.ContentEgressObserved || !row.ResponseEgressCompleted {
		t.Fatalf("empty completion confused with content: %+v", row)
	}
}

func TestAccountingResponsesReasoningOnlyEgress(t *testing.T) {
	tracker, pr := contentAccountingRequest("/v1/responses")
	w := httptest.NewRecorder()
	emitter := newResponsesStreamEmitter(w, w, pr, "response-id", 1)
	emitter.start()
	if tracker.Snapshot().ContentEgressObserved {
		t.Fatal("response preamble counted as generated content")
	}
	emitter.handleChunk(`data: {"choices":[{"delta":{"reasoning_content":"thought"}}]}`)
	if !strings.Contains(w.Body.String(), "response.reasoning_summary_text.delta") || !tracker.Snapshot().ContentEgressObserved {
		t.Fatalf("written reasoning not recorded: %s", w.Body.String())
	}
}

func TestAccountingToolNameOnlyEgress(t *testing.T) {
	const chunk = `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-id","type":"function","function":{"name":"clock","arguments":""}}]}}]}`
	for _, endpoint := range []string{"/v1/messages", "/v1/responses"} {
		t.Run(endpoint, func(t *testing.T) {
			tracker, pr := contentAccountingRequest(endpoint)
			w := httptest.NewRecorder()
			if endpoint == "/v1/messages" {
				emitter := newMessagesStreamEmitter(w, w, pr)
				emitter.start()
				emitter.handleChunk(chunk)
				emitter.finish(protocol.UsageInfo{})
			} else {
				emitter := newResponsesStreamEmitter(w, w, pr, "response-id", 1)
				emitter.start()
				emitter.handleChunk(chunk)
			}
			if !strings.Contains(w.Body.String(), `"name":"clock"`) || !tracker.Snapshot().ContentEgressObserved {
				t.Fatalf("written tool name not recorded: %s", w.Body.String())
			}
		})
	}
}

func TestAccountingResponsesSplitToolNameEgress(t *testing.T) {
	tracker, pr := contentAccountingRequest("/v1/responses")
	w := httptest.NewRecorder()
	emitter := newResponsesStreamEmitter(w, w, pr, "response-id", 1)
	emitter.handleChunk(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-id","type":"function"}]}}]}`)
	if tracker.Snapshot().ContentEgressObserved {
		t.Fatal("tool ID counted as generated content")
	}
	emitter.handleChunk(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"clock"}}]}}]}`)
	if tracker.Snapshot().ContentEgressObserved {
		t.Fatal("buffered tool name counted before the adapter emitted it")
	}
	emitter.closeFunctionCalls()
	if !strings.Contains(w.Body.String(), `"name":"clock"`) || !tracker.Snapshot().ContentEgressObserved {
		t.Fatalf("name in completed output item not recorded: %s", w.Body.String())
	}
}

func TestAccountingNonstreamUsesAdapterOutput(t *testing.T) {
	for _, endpoint := range []string{"/v1/completions", "/v1/messages"} {
		t.Run(endpoint, func(t *testing.T) {
			tracker, pr := contentAccountingRequest(endpoint)
			pr.Accounting.Observe("content", "", 0)
			body := buildGenericEndpointResponse(pr, extractedMessage{Reasoning: "provider thought"}, protocol.UsageInfo{})
			w := httptest.NewRecorder()
			writeNonStreamBody(w, nil, body, tracker)
			row := tracker.Snapshot()
			if !tracker.HasContent() || strings.Contains(w.Body.String(), "provider thought") || row.ContentEgressObserved || !row.ResponseEgressCompleted {
				t.Fatalf("ingress reasoning omitted by adapter counted as egress: %+v body=%s", row, w.Body.String())
			}
		})
	}
}

func TestAccountingNonstreamActualEnvelopes(t *testing.T) {
	for _, tc := range []struct {
		name string
		body any
		want bool
	}{
		{"empty chat", types.ChatCompletionResponse{Choices: []types.ChatCompletionChoice{{Message: types.ChatCompletionMessage{Role: "assistant"}}}}, false},
		{"chat text", types.ChatCompletionResponse{Choices: []types.ChatCompletionChoice{{Message: types.ChatCompletionMessage{Content: "answer"}}}}, true},
		{"chat reasoning details", types.ChatCompletionResponse{Choices: []types.ChatCompletionChoice{{Message: types.ChatCompletionMessage{ReasoningDetails: []types.ReasoningDetail{{Type: "reasoning.text", Text: "thought"}}}}}}, true},
		{"chat tool", &types.ChatCompletionResponse{Choices: []types.ChatCompletionChoice{{Message: types.ChatCompletionMessage{ToolCalls: []map[string]any{{"function": map[string]any{"name": "clock"}}}}}}}, true},
		{"empty responses", types.ResponsesResponse{Status: "completed", Output: []any{}}, false},
		{"responses text", &types.ResponsesResponse{Output: []any{map[string]any{"type": "message", "content": []any{map[string]any{"type": "output_text", "text": "answer"}}}}}, true},
		{"messages tool", map[string]any{"type": "message", "content": []any{map[string]any{"type": "tool_use", "name": "clock", "input": map[string]any{}}}}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tracker, _ := contentAccountingRequest("/v1/chat/completions")
			w := httptest.NewRecorder()
			writeNonStreamBody(w, nil, tc.body, tracker)
			if got := tracker.Snapshot().ContentEgressObserved; got != tc.want {
				t.Fatalf("content=%t, want %t; emitted=%s", got, tc.want, w.Body.String())
			}
		})
	}
}

func TestAccountingNativeResponsesTerminal(t *testing.T) {
	for _, tc := range []struct{ kind, status, want string }{
		{"response.completed", "completed", "completed"},
		{"response.incomplete", "incomplete", "incomplete"},
		{"response.failed", "failed", "error"},
		{"response.completed", "", "unknown"},
		{"response.output_text.delta", "completed", "unknown"},
	} {
		t.Run(tc.kind+tc.status, func(t *testing.T) {
			tracker, pr := contentAccountingRequest("/v1/chat/completions")
			pr.Accounting.Observe("committed", "", 0)
			pr.Accounting.Observe("provider_complete", "", 0)
			w := httptest.NewRecorder()
			relay := newChatStreamRelay(pr, w, w, newRelayStamps(nil, tracker))
			relay.handleChunk(`data: {"type":"` + tc.kind + `","response":{"status":"` + tc.status + `"}}`)
			relay.flush()
			tracker.Finish(200, false, false)
			row := tracker.Snapshot()
			if row.ResponseTerminal != tc.want || row.ContentEgressObserved || (row.Termination == "completed") != (tc.want == "completed") {
				t.Fatalf("native terminal classification: %+v", row)
			}
		})
	}
}

func TestAccountingNonstreamErrorTerminal(t *testing.T) {
	for _, body := range []any{
		map[string]any{"object": "chat.completion", "error": map[string]any{"message": "failed"}},
		map[string]any{"type": "error"},
		types.ResponsesResponse{Status: "completed", Error: "failed"},
		&types.ResponsesResponse{Status: "failed"},
	} {
		tracker, pr := contentAccountingRequest("/v1/responses")
		pr.Accounting.Observe("committed", "", 0)
		pr.Accounting.Observe("provider_complete", "", 0)
		writeNonStreamBody(httptest.NewRecorder(), nil, body, tracker)
		tracker.Finish(200, false, false)
		if row := tracker.Snapshot(); row.ResponseTerminal != "error" || row.Termination == "completed" {
			t.Fatalf("error envelope counted as completion: %+v", row)
		}
	}
}
