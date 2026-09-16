package response

import (
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
)

func TestResponsesEchoEnforcedToolPolicy(t *testing.T) {
	traits := registry.RequestTraits{
		ToolChoiceMode:    string(toolpolicy.Named),
		ToolChoiceName:    "weather",
		ParallelToolCalls: false,
	}
	snapshot := responsesSnapshot(
		"resp", 1, "model", "in_progress", nil, nil, nil, traits)
	if snapshot["parallel_tool_calls"] != false {
		t.Fatalf("stream snapshot lost parallel policy: %#v", snapshot)
	}
	choice, ok := snapshot["tool_choice"].(map[string]any)
	if !ok || choice["type"] != "function" || choice["name"] != "weather" {
		t.Fatalf("stream snapshot lost named choice: %#v", snapshot)
	}
	response := buildResponsesResponse(
		"request", "model", extractedMessage{Content: "ok"},
		protocol.UsageInfo{}, 16, "", "", traits)
	if response.ParallelToolCalls || response.ToolChoice == nil {
		t.Fatalf("nonstreaming response lost tool policy: %+v", response)
	}
}
