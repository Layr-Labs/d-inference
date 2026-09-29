package promptwork

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Shape contains only numeric properties of the exact provider JSON body. Byte
// counts use the received JSON bytes (including escaping), never a re-encoding.
// Keeping schema and history separate prevents an unchanged text estimate from
// certifying arbitrarily large tool overhead.
type Shape struct {
	BodyBytes             int `json:"body_bytes"`
	MessageCount          int `json:"message_count"`
	MessageBytes          int `json:"message_bytes"`
	SystemMessageCount    int `json:"system_message_count"`
	DeveloperMessageCount int `json:"developer_message_count"`
	AssistantMessageCount int `json:"assistant_message_count"`
	ToolDefinitionCount   int `json:"tool_definition_count"`
	ToolDefinitionBytes   int `json:"tool_definition_bytes"`
	ToolCallCount         int `json:"tool_call_count"`
	ToolCallBytes         int `json:"tool_call_bytes"`
	ToolResultCount       int `json:"tool_result_count"`
	ToolResultBytes       int `json:"tool_result_bytes"`
}

type ShapeRange struct {
	Min int `json:"min"`
	Max int `json:"max"`
}

// ShapeDomain is mandatory reviewed corpus coverage. Zero/zero bounds mean the
// feature was absent; a missing domain never grants unbounded feature support.
type ShapeDomain struct {
	BodyBytes             ShapeRange `json:"body_bytes"`
	MessageCount          ShapeRange `json:"message_count"`
	MessageBytes          ShapeRange `json:"message_bytes"`
	SystemMessageCount    ShapeRange `json:"system_message_count"`
	DeveloperMessageCount ShapeRange `json:"developer_message_count"`
	AssistantMessageCount ShapeRange `json:"assistant_message_count"`
	ToolDefinitionCount   ShapeRange `json:"tool_definition_count"`
	ToolDefinitionBytes   ShapeRange `json:"tool_definition_bytes"`
	ToolCallCount         ShapeRange `json:"tool_call_count"`
	ToolCallBytes         ShapeRange `json:"tool_call_bytes"`
	ToolResultCount       ShapeRange `json:"tool_result_count"`
	ToolResultBytes       ShapeRange `json:"tool_result_bytes"`
}

func (d *ShapeDomain) Contains(s Shape) bool {
	if d == nil || s.BodyBytes <= 0 || s.BodyBytes > promptcontract.DefaultMaxRequestBytes {
		return false
	}
	pairs := [...]struct {
		bounds ShapeRange
		value  int
	}{
		{d.BodyBytes, s.BodyBytes}, {d.MessageCount, s.MessageCount}, {d.MessageBytes, s.MessageBytes},
		{d.SystemMessageCount, s.SystemMessageCount}, {d.DeveloperMessageCount, s.DeveloperMessageCount}, {d.AssistantMessageCount, s.AssistantMessageCount},
		{d.ToolDefinitionCount, s.ToolDefinitionCount}, {d.ToolDefinitionBytes, s.ToolDefinitionBytes},
		{d.ToolCallCount, s.ToolCallCount}, {d.ToolCallBytes, s.ToolCallBytes}, {d.ToolResultCount, s.ToolResultCount}, {d.ToolResultBytes, s.ToolResultBytes},
	}
	for _, p := range pairs {
		if p.bounds.Min < 0 || p.bounds.Max < p.bounds.Min || p.bounds.Max > promptcontract.DefaultMaxRequestBytes || p.value < p.bounds.Min || p.value > p.bounds.Max {
			return false
		}
	}
	return true
}

// ShapeFromBody supports ordinary text/tool chat requests. New or multimodal
// content forms stay unqualified until their numeric domain is measured.
func ShapeFromBody(body []byte) (Shape, bool) {
	if len(body) == 0 || len(body) > promptcontract.DefaultMaxRequestBytes {
		return Shape{}, false
	}
	var request map[string]json.RawMessage
	if json.Unmarshal(body, &request) != nil || request == nil {
		return Shape{}, false
	}
	// Deprecated function forms have distinct rendering semantics. Their exact
	// tokenizer path remains available; this initial fallback has no domain.
	if request["functions"] != nil || request["function_call"] != nil {
		return Shape{}, false
	}
	var messages []json.RawMessage
	if json.Unmarshal(request["messages"], &messages) != nil || len(messages) == 0 {
		return Shape{}, false
	}
	s := Shape{BodyBytes: len(body), MessageCount: len(messages)}
	for _, raw := range messages {
		var message map[string]json.RawMessage
		if json.Unmarshal(raw, &message) != nil || message == nil || message["function_call"] != nil {
			return Shape{}, false
		}
		var role string
		if json.Unmarshal(message["role"], &role) != nil {
			return Shape{}, false
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
			return Shape{}, false
		}
		if content := message["content"]; len(content) > 0 && string(content) != "null" {
			var text string
			if json.Unmarshal(content, &text) != nil {
				return Shape{}, false
			}
		}
		if calls := message["tool_calls"]; len(calls) > 0 && string(calls) != "null" {
			var values []json.RawMessage
			if json.Unmarshal(calls, &values) != nil {
				return Shape{}, false
			}
			for _, call := range values {
				if !functionObject(call) {
					return Shape{}, false
				}
				s.ToolCallCount++
				s.ToolCallBytes += len(call)
			}
		}
	}
	if tools := request["tools"]; len(tools) > 0 && string(tools) != "null" {
		var values []json.RawMessage
		if json.Unmarshal(tools, &values) != nil {
			return Shape{}, false
		}
		for _, tool := range values {
			if !functionObject(tool) {
				return Shape{}, false
			}
			s.ToolDefinitionCount++
			s.ToolDefinitionBytes += len(tool)
		}
	}
	return s, true
}

func functionObject(raw []byte) bool {
	var value struct {
		Type     string                     `json:"type"`
		Function map[string]json.RawMessage `json:"function"`
	}
	return json.Unmarshal(raw, &value) == nil && value.Type == "function" && value.Function != nil
}
