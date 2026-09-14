package response

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// responsesSnapshot builds the full Response object embedded in lifecycle
// events (response.created / response.in_progress / response.completed /
// response.incomplete). All spec-required fields are present so strict SDK
// parsers accept the snapshot.
func responsesSnapshot(responseID string, createdAt int64, model, status string, output []any, usage *types.ResponsesUsage, incomplete *types.ResponsesIncompleteDetail, policies ...registry.RequestTraits) map[string]any {
	if output == nil {
		output = []any{}
	}
	var traits registry.RequestTraits
	if len(policies) > 0 {
		traits = policies[0]
	}
	toolChoice, parallel := responsesToolPolicy(traits)
	snap := map[string]any{
		"id":                   responseID,
		"object":               "response",
		"created_at":           createdAt,
		"status":               status,
		"background":           false,
		"error":                nil,
		"incomplete_details":   nil,
		"instructions":         nil,
		"max_output_tokens":    nil,
		"model":                model,
		"output":               output,
		"parallel_tool_calls":  parallel,
		"previous_response_id": nil,
		"store":                false,
		"temperature":          nil,
		"text":                 map[string]any{"format": map[string]any{"type": "text"}},
		"tool_choice":          toolChoice,
		"tools":                []any{},
		"top_p":                nil,
		"truncation":           "disabled",
		"usage":                nil,
		"user":                 nil,
		"metadata":             map[string]any{},
		"service_tier":         nil,
	}
	if usage != nil {
		snap["usage"] = usage
	}
	if incomplete != nil {
		snap["incomplete_details"] = incomplete
	}
	return snap
}

func responsesToolPolicy(traits registry.RequestTraits) (any, bool) {
	if traits.ToolChoiceMode == "" {
		return "auto", true
	}
	switch traits.ToolChoiceMode {
	case string(toolpolicy.None):
		return "none", traits.ParallelToolCalls
	case string(toolpolicy.Required):
		return "required", traits.ParallelToolCalls
	case string(toolpolicy.Named):
		return map[string]any{
			"type": "function",
			"name": traits.ToolChoiceName,
		}, traits.ParallelToolCalls
	default:
		return "auto", traits.ParallelToolCalls
	}
}
