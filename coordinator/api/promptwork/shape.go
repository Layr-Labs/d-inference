package promptwork

import (
	"encoding/json"

	calibration "github.com/eigeninference/d-inference/coordinator/internal/promptwork/calibration"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// ShapeFromBody supports the measured text/tool rendering mode. New controls or
// multimodal content stay unqualified; the exact tokenizer remains available.
func ShapeFromBody(body []byte) (calibration.Shape, bool) {
	if len(body) == 0 || len(body) > promptcontract.DefaultMaxRequestBytes {
		return calibration.Shape{}, false
	}
	var request map[string]json.RawMessage
	if json.Unmarshal(body, &request) != nil || request == nil {
		return calibration.Shape{}, false
	}
	if !measuredRenderControls(request) {
		return calibration.Shape{}, false
	}
	var messages []json.RawMessage
	if json.Unmarshal(request["messages"], &messages) != nil || len(messages) == 0 {
		return calibration.Shape{}, false
	}
	s := calibration.Shape{BodyBytes: len(body), MessageCount: len(messages)}
	for _, raw := range messages {
		var message map[string]json.RawMessage
		if json.Unmarshal(raw, &message) != nil || message == nil {
			return calibration.Shape{}, false
		}
		// name, reasoning_content and legacy function_call can change the
		// rendered history. None occurred in the reviewed corpus.
		for key := range message {
			switch key {
			case "role", "content", "tool_calls", "tool_call_id":
			default:
				return calibration.Shape{}, false
			}
		}
		var role string
		if json.Unmarshal(message["role"], &role) != nil {
			return calibration.Shape{}, false
		}
		s.MessageBytes += len(raw)
		switch role {
		case "system":
			s.SystemMessageCount++
		case "developer":
			s.DeveloperMessageCount++
		case "assistant":
			s.AssistantMessageCount++
		case "tool":
			s.ToolResultCount++
			s.ToolResultBytes += len(raw)
		case "user":
		default:
			return calibration.Shape{}, false
		}
		if content := message["content"]; len(content) > 0 && string(content) != "null" {
			var text string
			if json.Unmarshal(content, &text) != nil {
				return calibration.Shape{}, false
			}
		}
		if calls := message["tool_calls"]; len(calls) > 0 && string(calls) != "null" {
			var values []json.RawMessage
			if json.Unmarshal(calls, &values) != nil {
				return calibration.Shape{}, false
			}
			for _, call := range values {
				if !measuredFunctionObject(call, true) {
					return calibration.Shape{}, false
				}
				s.ToolCallCount++
				s.ToolCallBytes += len(call)
			}
		}
	}
	if tools := request["tools"]; len(tools) > 0 && string(tools) != "null" {
		var values []json.RawMessage
		if json.Unmarshal(tools, &values) != nil {
			return calibration.Shape{}, false
		}
		for _, tool := range values {
			if !measuredFunctionObject(tool, false) {
				return calibration.Shape{}, false
			}
			s.ToolDefinitionCount++
			s.ToolDefinitionBytes += len(tool)
		}
	}
	return s, true
}
