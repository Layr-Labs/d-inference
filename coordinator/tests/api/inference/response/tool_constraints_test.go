package response_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/response"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"

	responsepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/responsepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestResponsesEchoEnforcedToolPolicy(t *testing.T) {
	traits := registry.RequestTraits{
		ToolChoiceMode:    string(inreq.ToolChoiceNamed),
		ToolChoiceName:    "weather",
		ParallelToolCalls: false,
	}
	snapshot := responsepolicy.ResponsesSnapshot(
		"resp", 1, "model", "in_progress", nil, nil, nil, traits)
	if snapshot["parallel_tool_calls"] != false {
		t.Fatalf("stream snapshot lost parallel policy: %#v", snapshot)
	}
	choice, ok := snapshot["tool_choice"].(map[string]any)
	if !ok || choice["type"] != "function" || choice["name"] != "weather" {
		t.Fatalf("stream snapshot lost named choice: %#v", snapshot)
	}
	response := production.BuildResponsesResponse(
		"request", "model", production.ExtractedMessage{Content: "ok"},
		protocol.UsageInfo{}, 16, "", "", traits)
	if response.ParallelToolCalls || response.ToolChoice == nil {
		t.Fatalf("nonstreaming response lost tool policy: %+v", response)
	}
}
