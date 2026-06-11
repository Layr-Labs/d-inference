package api

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func newTestEmitter(t *testing.T) (*responsesStreamEmitter, *httptest.ResponseRecorder) {
	t.Helper()
	rec := httptest.NewRecorder()
	pr := &registry.PendingRequest{RequestID: "req-test", RequestedMaxTokens: 100}
	return newResponsesStreamEmitter(rec, rec, pr, "resp_test", 1700000000), rec
}

type sseEvent struct {
	Type string
	Data map[string]any
}

func parseSSEEvents(t *testing.T, body string) []sseEvent {
	t.Helper()
	var events []sseEvent
	for _, block := range strings.Split(body, "\n\n") {
		var data string
		for _, line := range strings.Split(block, "\n") {
			if strings.HasPrefix(line, "data: ") {
				data = strings.TrimPrefix(line, "data: ")
			}
		}
		if data == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(data), &m); err != nil {
			t.Fatalf("bad SSE data %q: %v", data, err)
		}
		typ, _ := m["type"].(string)
		events = append(events, sseEvent{Type: typ, Data: m})
	}
	return events
}

func TestResponsesStreamInterleavedToolCalls(t *testing.T) {
	e, rec := newTestEmitter(t)
	e.start()
	chunks := []string{
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":"{\"ci"}},{"index":1,"id":"call_b","type":"function","function":{"name":"get_time","arguments":"{\"tz"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\":\"UTC\"}"}},{"index":0,"function":{"arguments":"ty\":\"SF\"}"}}]}}]}`,
		`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
	}
	for _, c := range chunks {
		e.handleChunk(c)
	}
	e.finish(protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 10})

	events := parseSSEEvents(t, rec.Body.String())
	var completed map[string]any
	for _, ev := range events {
		if ev.Type == "response.completed" {
			completed = ev.Data
		}
	}
	if completed == nil {
		t.Fatal("no response.completed event")
	}
	resp := completed["response"].(map[string]any)
	output := resp["output"].([]any)
	if len(output) != 2 {
		t.Fatalf("output items = %d, want 2: %#v", len(output), output)
	}
	type want struct{ callID, name, args string }
	wants := []want{
		{"call_a", "get_weather", `{"city":"SF"}`},
		{"call_b", "get_time", `{"tz":"UTC"}`},
	}
	for i, w := range wants {
		item := output[i].(map[string]any)
		if item["type"] != "function_call" {
			t.Errorf("output[%d].type = %v, want function_call", i, item["type"])
		}
		if item["call_id"] != w.callID {
			t.Errorf("output[%d].call_id = %v, want %s", i, item["call_id"], w.callID)
		}
		if item["name"] != w.name {
			t.Errorf("output[%d].name = %v, want %s", i, item["name"], w.name)
		}
		if item["arguments"] != w.args {
			t.Errorf("output[%d].arguments = %v, want %s", i, item["arguments"], w.args)
		}
		if item["status"] != "completed" {
			t.Errorf("output[%d].status = %v, want completed", i, item["status"])
		}
	}

	// Each call's deltas must reference its own item and reserved output_index.
	itemIDs := map[string]float64{}
	for _, ev := range events {
		if ev.Type == "response.function_call_arguments.delta" {
			id := ev.Data["item_id"].(string)
			idx := ev.Data["output_index"].(float64)
			if prev, ok := itemIDs[id]; ok && prev != idx {
				t.Errorf("item %s output_index changed %v -> %v", id, prev, idx)
			}
			itemIDs[id] = idx
		}
	}
	if len(itemIDs) != 2 {
		t.Errorf("distinct delta item ids = %d, want 2", len(itemIDs))
	}
}

func TestResponsesStreamEmptyOutputSynthesizesMessage(t *testing.T) {
	e, rec := newTestEmitter(t)
	e.start()
	e.handleChunk(`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`)
	e.finish(protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 0})

	events := parseSSEEvents(t, rec.Body.String())
	sawTextDone := false
	var completed map[string]any
	for _, ev := range events {
		if ev.Type == "response.output_text.done" {
			sawTextDone = true
			if ev.Data["text"] != "" {
				t.Errorf("output_text.done text = %v, want empty", ev.Data["text"])
			}
		}
		if ev.Type == "response.completed" {
			completed = ev.Data
		}
	}
	if !sawTextDone {
		t.Error("missing response.output_text.done for empty stream")
	}
	if completed == nil {
		t.Fatal("no response.completed event")
	}
	output := completed["response"].(map[string]any)["output"].([]any)
	if len(output) != 1 {
		t.Fatalf("output items = %d, want 1 empty message", len(output))
	}
	item := output[0].(map[string]any)
	if item["type"] != "message" || item["status"] != "completed" {
		t.Errorf("synthesized item = %#v, want completed message", item)
	}
}

func TestEffectiveFinishReasonTruncatedToolCalls(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 100}
	if got := effectiveFinishReason("stop", true, usage, 100); got != "length" {
		t.Errorf("truncated tool-call response finish_reason = %q, want length", got)
	}
	usage.CompletionTokens = 10
	if got := effectiveFinishReason("stop", true, usage, 100); got != "tool_calls" {
		t.Errorf("untruncated tool-call response finish_reason = %q, want tool_calls", got)
	}
}
