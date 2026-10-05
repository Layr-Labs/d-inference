package calibration

import (
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
