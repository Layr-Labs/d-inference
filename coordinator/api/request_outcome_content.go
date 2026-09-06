package api

import (
	"encoding/json"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// accountingChunkHasContent is separate from isBoilerplateChunk: routing can
// commit on finish/usage/DONE or unknown data, which is not generated content.
// The caller stops parsing after the first content observation. Parsed values
// never enter the tracker, sink, logs or store.
func accountingChunkHasContent(chunk string) bool {
	if strings.HasPrefix(strings.TrimSpace(chunk), "{") {
		return accountingJSONHasContent([]byte(chunk))
	}
	for line := range strings.SplitSeq(chunk, "\n") {
		if data, ok := strings.CutPrefix(line, "data:"); ok && accountingJSONHasContent([]byte(strings.TrimSpace(data))) {
			return true
		}
	}
	return false
}

func accountingJSONHasContent(data []byte) bool {
	var value map[string]any
	if json.Unmarshal(data, &value) != nil {
		return false
	}
	return accountingValueHasContent(value, 0)
}

// responseAccountingHasContent examines the response already assembled by the
// endpoint. Ingress reasoning omitted by the completions/messages adapter must
// not be treated as delivered output. This does not reparse the response body.
func responseAccountingHasContent(value any) bool {
	switch response := value.(type) {
	case types.ChatCompletionResponse:
		for _, choice := range response.Choices {
			m := choice.Message
			if m.Content != "" || m.Reasoning != "" || m.ReasoningContent != "" || accountingReasoningDetails(m.ReasoningDetails) {
				return true
			}
			for _, call := range m.ToolCalls {
				if accountingToolCallHasContent(call) {
					return true
				}
			}
		}
	case *types.ChatCompletionResponse:
		if response != nil {
			return responseAccountingHasContent(*response)
		}
	case types.ResponsesResponse:
		return accountingValueHasContent(response.Output, 0)
	case *types.ResponsesResponse:
		if response != nil {
			return accountingValueHasContent(response.Output, 0)
		}
	default:
		return accountingValueHasContent(value, 0)
	}
	return false
}

func accountingToolCallHasContent(call map[string]any) bool {
	function, _ := call["function"].(map[string]any)
	name, _ := function["name"].(string)
	arguments, _ := function["arguments"].(string)
	return name != "" || arguments != ""
}

// Traverse only endpoint-defined output fields, bounded against malformed nested
// shapes. IDs, role, finish reasons, usage, errors and metadata are not content.
func accountingValueHasContent(value any, depth int) bool {
	if depth > 8 {
		return false
	}
	switch v := value.(type) {
	case string:
		return v != ""
	case []map[string]any:
		for _, item := range v {
			if accountingValueHasContent(item, depth+1) {
				return true
			}
		}
	case []any:
		for _, item := range v {
			if accountingValueHasContent(item, depth+1) {
				return true
			}
		}
	case map[string]any:
		kind, _ := v["type"].(string)
		switch kind {
		case "response.output_text.delta", "response.reasoning_text.delta", "response.reasoning_summary_text.delta", "response.function_call_arguments.delta", "response.refusal.delta":
			delta, _ := v["delta"].(string)
			return delta != ""
		case "error", "response.failed", "response.created", "response.in_progress":
			return false
		case "response.completed", "response.incomplete":
			return accountingValueHasContent(v["response"], depth+1)
		case "content_block_delta":
			return accountingValueHasContent(v["delta"], depth+1)
		case "content_block_start":
			return accountingValueHasContent(v["content_block"], depth+1)
		case "response.output_item.added", "response.output_item.done":
			return accountingValueHasContent(v["item"], depth+1)
		case "function_call", "tool_use":
			name, _ := v["name"].(string)
			arguments, _ := v["arguments"].(string)
			return name != "" || arguments != ""
		}
		if accountingReasoningDetails(v["reasoning_details"]) {
			return true
		}
		for _, field := range []string{"text", "reasoning", "reasoning_content", "refusal", "thinking", "partial_json"} {
			if text, ok := v[field].(string); ok && text != "" {
				return true
			}
		}
		for _, field := range []string{"content", "choices", "output", "summary"} {
			if accountingValueHasContent(v[field], depth+1) {
				return true
			}
		}
		for _, field := range []string{"message", "delta"} {
			if nested, ok := v[field].(map[string]any); ok && accountingValueHasContent(nested, depth+1) {
				return true
			}
		}
		if calls, ok := v["tool_calls"].([]any); ok {
			for _, item := range calls {
				if call, ok := item.(map[string]any); ok && accountingToolCallHasContent(call) {
					return true
				}
			}
		}
	}
	return false
}

func accountingReasoningDetails(value any) bool {
	switch details := value.(type) {
	case []types.ReasoningDetail:
		for _, detail := range details {
			if detail.Type == "reasoning.text" && detail.Text != "" {
				return true
			}
		}
	case []any:
		for _, detail := range details {
			if item, ok := detail.(map[string]any); ok && accountingReasoningText(item) {
				return true
			}
		}
	case []map[string]any:
		for _, detail := range details {
			if accountingReasoningText(detail) {
				return true
			}
		}
	}
	return false
}

func accountingReasoningText(detail map[string]any) bool {
	kind, _ := detail["type"].(string)
	text, _ := detail["text"].(string)
	return kind == "reasoning.text" && text != ""
}
