package response

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestResponsesStreamReopenedItemsContainOnlyTheirOwnText(t *testing.T) {
	for _, reasoningTokens := range []int{0, 7} {
		e, rec := newTestEmitter(t)
		e.Start()
		for _, chunk := range []string{
			`data: {"choices":[{"delta":{"reasoning":"first plan"}}]}`,
			`data: {"choices":[{"delta":{"content":"before tool"}}]}`,
			`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":"{}"}}]}}]}`,
			`data: {"choices":[{"delta":{"reasoning_content":"second plan"}}]}`,
			`data: {"choices":[{"delta":{"content":"after tool"}}]}`,
		} {
			e.Chunk(chunk)
		}
		e.Finish(protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 20, ReasoningTokens: reasoningTokens})

		deltas := map[string]string{}
		var completed map[string]any
		for _, event := range parseSSEEvents(t, rec.Body.String()) {
			id, _ := event.Data["item_id"].(string)
			switch event.Type {
			case "response.output_text.delta", "response.reasoning_summary_text.delta":
				delta, _ := event.Data["delta"].(string)
				deltas[id] += delta
			case "response.output_text.done", "response.reasoning_summary_text.done":
				if event.Data["text"] != deltas[id] {
					t.Errorf("%s text = %q, want its own deltas %q", event.Type, event.Data["text"], deltas[id])
				}
			case "response.completed":
				completed, _ = event.Data["response"].(map[string]any)
			}
		}
		if completed == nil {
			t.Fatal("missing completed response")
		}
		output, _ := completed["output"].([]any)
		want := []struct{ kind, text string }{
			{"reasoning", "first plan"}, {"message", "before tool"},
			{"function_call", ""}, {"reasoning", "second plan"}, {"message", "after tool"},
		}
		if len(output) != len(want) {
			t.Fatalf("output items = %d, want %d", len(output), len(want))
		}
		for i, expectation := range want {
			item := output[i].(map[string]any)
			if item["type"] != expectation.kind {
				t.Fatalf("item %d type = %v, want %s", i, item["type"], expectation.kind)
			}
			field := "content"
			if expectation.kind == "reasoning" {
				field = "summary"
			} else if expectation.kind == "function_call" {
				continue
			}
			parts := item[field].([]any)
			if len(parts) != 1 || parts[0].(map[string]any)["text"] != expectation.text {
				t.Errorf("item %d %s = %#v, want %q", i, field, parts, expectation.text)
			}
		}
		usage := completed["usage"].(map[string]any)
		details := usage["output_tokens_details"].(map[string]any)
		wantReasoning := reasoningTokens
		if wantReasoning == 0 {
			wantReasoning = 20 // Preserve the legacy completion-token fallback.
		}
		if details["reasoning_tokens"] != float64(wantReasoning) {
			t.Errorf("reasoning tokens = %v, want %d", details["reasoning_tokens"], wantReasoning)
		}
	}
}
