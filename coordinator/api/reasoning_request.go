package api

import (
	"encoding/json"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// reasoningRequestPolicy is the coordinator-side decode of OpenRouter /
// OpenAI reasoning controls. Qwen3.6's chat template thinks by default
// unless enable_thinking is boolean false; OpenRouter disables reasoning
// via several equivalent shapes (enabled=false, effort=none, max_tokens=0).
// SuppressOutput is the consumer-visible contract: the reasoning field
// length must be 0 when the caller disabled or excluded reasoning.
type reasoningRequestPolicy struct {
	ThinkingEnabled *bool
	Effort          string
	SuppressOutput  bool
}

func parseReasoningRequestFromBody(rawBody []byte) reasoningRequestPolicy {
	parsed, err := decodeInferenceJSONObject(rawBody)
	if err != nil {
		return reasoningRequestPolicy{}
	}
	return parseReasoningRequest(parsed)
}

func parseReasoningRequest(parsed map[string]any) reasoningRequestPolicy {
	var policy reasoningRequestPolicy
	if parsed == nil {
		return policy
	}

	if flag, ok := parsed["enable_thinking"].(bool); ok && !flag {
		disabled := false
		policy.ThinkingEnabled = &disabled
	}
	if kwargs, ok := parsed["chat_template_kwargs"].(map[string]any); ok {
		if flag, ok := kwargs["enable_thinking"].(bool); ok && !flag {
			disabled := false
			policy.ThinkingEnabled = &disabled
		}
	}
	if include, ok := parsed["include_reasoning"].(bool); ok && !include {
		policy.SuppressOutput = true
	}
	if effort, ok := stringFromRequestValue(parsed["reasoning_effort"]); ok {
		policy.Effort = effort
		if isNoneReasoningEffort(effort) {
			disabled := false
			policy.ThinkingEnabled = &disabled
		}
	}
	applyReasoningValue(parsed["reasoning"], &policy)
	if policy.ThinkingEnabled != nil && !*policy.ThinkingEnabled {
		policy.SuppressOutput = true
	}
	return policy
}

func stampReasoningPolicy(pr *registry.PendingRequest, rawBody []byte) {
	if pr == nil {
		return
	}
	pr.SuppressReasoningOutput = parseReasoningRequestFromBody(rawBody).SuppressOutput
}

func applyReasoningValue(value any, policy *reasoningRequestPolicy) {
	switch typed := value.(type) {
	case bool:
		policy.ThinkingEnabled = &typed
	case map[string]any:
		if enabled, ok := typed["enabled"].(bool); ok {
			policy.ThinkingEnabled = &enabled
		}
		if effort, ok := stringFromRequestValue(typed["effort"]); ok {
			policy.Effort = effort
			if isNoneReasoningEffort(effort) {
				disabled := false
				policy.ThinkingEnabled = &disabled
			}
		}
		if exclude, ok := typed["exclude"].(bool); ok && exclude {
			policy.SuppressOutput = true
		}
		if n, ok := intFromRequestValue(typed["max_tokens"]); ok && n == 0 {
			disabled := false
			policy.ThinkingEnabled = &disabled
		}
	}
}

func isNoneReasoningEffort(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "none", "off", "disabled":
		return true
	default:
		return false
	}
}

func stringFromRequestValue(value any) (string, bool) {
	text, ok := value.(string)
	if !ok {
		return "", false
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return "", false
	}
	return text, true
}

func stripReasoningFromSSEChunk(chunk string) string {
	prefix := ""
	line := chunk
	if strings.HasPrefix(chunk, "data: ") {
		prefix = "data: "
		line = strings.TrimPrefix(chunk, "data: ")
	}
	if !strings.Contains(line, `"reasoning`) {
		return chunk
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return chunk
	}
	choicesRaw, ok := raw["choices"]
	if !ok {
		return chunk
	}
	var choices []map[string]json.RawMessage
	if err := json.Unmarshal(choicesRaw, &choices); err != nil {
		return chunk
	}
	changed := false
	for i, choice := range choices {
		for _, field := range []string{"delta", "message"} {
			nestedRaw, ok := choice[field]
			if !ok {
				continue
			}
			var nested map[string]json.RawMessage
			if err := json.Unmarshal(nestedRaw, &nested); err != nil {
				continue
			}
			if stripReasoningFields(nested) {
				encoded, err := json.Marshal(nested)
				if err != nil {
					continue
				}
				choices[i][field] = encoded
				changed = true
			}
		}
	}
	if !changed {
		return chunk
	}
	encodedChoices, err := json.Marshal(choices)
	if err != nil {
		return chunk
	}
	raw["choices"] = encodedChoices
	out, err := json.Marshal(raw)
	if err != nil {
		return chunk
	}
	return prefix + string(out)
}

func stripReasoningFromCompleteResponse(obj map[string]any) {
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if message, ok := choice["message"].(map[string]any); ok {
			delete(message, "reasoning")
			delete(message, "reasoning_content")
		}
		if delta, ok := choice["delta"].(map[string]any); ok {
			delete(delta, "reasoning")
			delete(delta, "reasoning_content")
		}
	}
}

func stripReasoningFields(fields map[string]json.RawMessage) bool {
	changed := false
	for _, key := range []string{"reasoning", "reasoning_content"} {
		if _, ok := fields[key]; ok {
			delete(fields, key)
			changed = true
		}
	}
	return changed
}

func maybeStripReasoningSSE(chunk string, suppress bool) string {
	if !suppress {
		return chunk
	}
	return stripReasoningFromSSEChunk(chunk)
}
