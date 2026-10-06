package promptwork

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// The corpus pins reasoning.enabled=false. An omitted control is different:
// Qwen's template defaults thinking on. Do not generalize this evidence to
// aliases, effort settings or new rendering inputs, even if numeric sizes fit.
func measuredRenderControls(request map[string]json.RawMessage) bool {
	for key := range request {
		switch key {
		case "model", "messages", "tools", "tool_choice", "reasoning":
		case promptcontract.RequestDateField:
			// Coordinator-owned date pinning preserves the provider's current-date
			// template context across retries; it is not a caller render override.
		case "stream", "stream_options", "max_tokens", "max_completion_tokens",
			"temperature", "top_p", "top_k", "min_p", "seed", "stop",
			"presence_penalty", "frequency_penalty", "repetition_penalty",
			"logit_bias", "logprobs", "top_logprobs", "n",
			"parallel_tool_calls", "tool_call_parser", "reasoning_parser",
			"user", "metadata", "store", "service_tier", "safety_identifier",
			"prompt_cache_key", "prompt_cache_retention":
			// Sampling, output parsing and transport fields do not affect the
			// provider's rendered prompt in the supported automatic tool mode.
		default:
			return false
		}
	}
	var reasoning map[string]json.RawMessage
	var enabled *bool
	if json.Unmarshal(request["reasoning"], &reasoning) != nil || len(reasoning) != 1 ||
		json.Unmarshal(reasoning["enabled"], &enabled) != nil || enabled == nil || *enabled {
		return false
	}
	// Absent/null and auto share ToolChoicePromptPolicy's unchanged messages
	// and tools. none/required/named instead inject or select prompt content.
	if raw := request["tool_choice"]; len(raw) > 0 && string(raw) != "null" {
		var choice string
		if json.Unmarshal(raw, &choice) != nil || choice != "auto" {
			return false
		}
	}
	return true
}

func measuredFunctionObject(raw []byte, call bool) bool {
	var value struct {
		Type        string                     `json:"type"`
		Function    map[string]json.RawMessage `json:"function"`
		Name        json.RawMessage            `json:"name"`
		Description json.RawMessage            `json:"description"`
		Parameters  json.RawMessage            `json:"parameters"`
		InputSchema json.RawMessage            `json:"input_schema"`
	}
	if json.Unmarshal(raw, &value) != nil || value.Type != "function" || value.Function == nil {
		return false
	}
	// OpenAITool can recover a malformed nested definition through flat fields.
	// Only the nested form was measured; never qualify that alternate renderer.
	if value.Name != nil || value.Description != nil || value.Parameters != nil || value.InputSchema != nil {
		return false
	}
	var name *string
	if json.Unmarshal(value.Function["name"], &name) != nil || name == nil {
		return false
	}
	if call {
		var arguments *string
		return json.Unmarshal(value.Function["arguments"], &arguments) == nil && arguments != nil
	}
	var description *string
	rawDescription := value.Function["description"]
	return rawDescription == nil || json.Unmarshal(rawDescription, &description) == nil
}
