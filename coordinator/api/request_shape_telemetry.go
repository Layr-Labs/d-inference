package api

// request_shape_telemetry.go builds the privacy-safe "service request shape"
// log line emitted once per admitted chat-completions request from a
// service-role consumer (e.g. OpenRouter). The goal is to see exactly which
// request shapes an upstream aggregator forwards — reasoning flags, sampling
// knobs, tool/vision traits — and join them by trace_id against terminal
// outcomes (client_gone / 504s) without ever logging prompt, message, or
// tool-schema CONTENT.
//
// Privacy contract: every string field comes from a CLOSED SET. Unrecognized
// consumer-supplied strings map to "other" — the raw value is never echoed.
// Numeric sampling params are logged only when the consumer sent a JSON
// number (never coerced from strings). Everything else is booleans, counts,
// and already-derived values (model/build ids, token estimates).

import (
	"encoding/json"
	"strings"
)

// Closed-set enum values shared by the shape fields below.
const (
	shapeAbsent  = "absent"
	shapeOther   = "other"
	shapeTrue    = "true"
	shapeFalse   = "false"
	shapeNonBool = "non_bool"
)

// requestShapeComputed carries values handleChatCompletions has already
// derived by the wiring point (post alias resolution, pre dispatch), so the
// log line agrees with routing/billing instead of re-deriving them.
type requestShapeComputed struct {
	traceID               string
	model                 string // resolved build id
	publicModel           string // consumer-facing alias
	stream                bool
	estimatedPromptTokens int
	requestedMaxTokens    int
	hasTools              bool
	requiresVision        bool
}

// serviceRequestShapeFields returns the alternating key/value slog args for
// the "service request shape" INFO line. Pure: reads parsed, mutates nothing.
//
// temperature / top_p / presence_penalty / frequency_penalty are emitted only
// when the request carried them as JSON numbers; otherwise the key is absent
// from the line entirely.
func serviceRequestShapeFields(parsed map[string]any, c requestShapeComputed) []any {
	reasoning, reasoningPresent := parsed["reasoning"]
	includeReasoning, includeReasoningPresent := parsed["include_reasoning"]
	_, hasChatTemplateKwargs := parsed["chat_template_kwargs"]
	_, seedPresent := parsed["seed"]
	_, logprobsPresent := parsed["logprobs"]
	responseFormat, responseFormatPresent := parsed["response_format"]

	toolCount := 0
	if tools, ok := parsed["tools"].([]any); ok {
		toolCount = len(tools)
	}
	// n: the requested choice count when numeric, 0 when absent/non-numeric.
	// (n > 1 is rejected before this point, so in practice 0 or 1.)
	n, _ := intFromRequestValue(parsed["n"])

	fields := make([]any, 0, 2*22)
	fields = append(fields,
		"trace_id", c.traceID,
		"model", c.model,
		"public_model", c.publicModel,
		"stream", c.stream,
		"reasoning_present", reasoningPresent,
		"reasoning_enabled", normalizeReasoningEnabled(reasoning, reasoningPresent),
		"reasoning_effort", normalizeReasoningEffort(parsed),
		"include_reasoning", normalizeBoolTriState(includeReasoning, includeReasoningPresent),
		"has_chat_template_kwargs", hasChatTemplateKwargs,
		"estimated_prompt_tokens", c.estimatedPromptTokens,
		"requested_max_tokens", c.requestedMaxTokens,
		"has_tools", c.hasTools,
		"tool_count", toolCount,
		"requires_vision", c.requiresVision,
		"n", n,
		"response_format", normalizeResponseFormat(responseFormat, responseFormatPresent),
	)
	for _, p := range [...]struct {
		key string
		val any
	}{
		{"temperature", parsed["temperature"]},
		{"top_p", parsed["top_p"]},
		{"presence_penalty", parsed["presence_penalty"]},
		{"frequency_penalty", parsed["frequency_penalty"]},
	} {
		if f, ok := jsonNumberValue(p.val); ok {
			fields = append(fields, p.key, f)
		}
	}
	fields = append(fields,
		"seed_present", seedPresent,
		"logprobs_present", logprobsPresent,
	)
	return fields
}

// normalizeReasoningEnabled classifies reasoning.enabled (the OpenRouter
// unified-reasoning toggle): "true" / "false" for a JSON bool, "non_bool" for
// any other present value, "absent" when the reasoning object or the enabled
// key is missing. A non-object reasoning value has no enabled key → "absent"
// (reasoning_present still records that the field was sent).
func normalizeReasoningEnabled(reasoning any, present bool) string {
	if !present {
		return shapeAbsent
	}
	obj, ok := reasoning.(map[string]any)
	if !ok {
		return shapeAbsent
	}
	enabled, ok := obj["enabled"]
	if !ok {
		return shapeAbsent
	}
	if b, ok := enabled.(bool); ok {
		if b {
			return shapeTrue
		}
		return shapeFalse
	}
	return shapeNonBool
}

// normalizeReasoningEffort classifies the requested reasoning effort from
// either surface — reasoning.effort (OpenRouter) with top-level
// reasoning_effort (OpenAI) as fallback — into the closed set
// none/minimal/low/medium/high/xhigh/max, "other" for any present but
// unrecognized value (raw string never logged), "absent" when neither field
// carries a value.
func normalizeReasoningEffort(parsed map[string]any) string {
	if obj, ok := parsed["reasoning"].(map[string]any); ok {
		if effort, ok := obj["effort"]; ok {
			return normalizeEffortValue(effort)
		}
	}
	if effort, ok := parsed["reasoning_effort"]; ok {
		return normalizeEffortValue(effort)
	}
	return shapeAbsent
}

func normalizeEffortValue(v any) string {
	s, ok := v.(string)
	if !ok {
		return shapeOther
	}
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "none":
		return "none"
	case "minimal":
		return "minimal"
	case "low":
		return "low"
	case "medium":
		return "medium"
	case "high":
		return "high"
	case "xhigh":
		return "xhigh"
	case "max":
		return "max"
	default:
		return shapeOther
	}
}

// normalizeBoolTriState classifies a bool-typed request field into
// "true" / "false" / "absent". A present non-bool value is outside the
// field's contract and collapses to "absent" rather than widening the set.
func normalizeBoolTriState(v any, present bool) string {
	if !present {
		return shapeAbsent
	}
	if b, ok := v.(bool); ok {
		if b {
			return shapeTrue
		}
		return shapeFalse
	}
	return shapeAbsent
}

// normalizeResponseFormat classifies response_format into
// json_schema/json_object/text (the OpenAI-defined types), "other" for any
// present but unrecognized shape or type string, "absent" when missing.
// Accepts both the object form {"type": "..."} and a bare type string.
func normalizeResponseFormat(v any, present bool) string {
	if !present {
		return shapeAbsent
	}
	var typ string
	switch x := v.(type) {
	case map[string]any:
		s, ok := x["type"].(string)
		if !ok {
			return shapeOther
		}
		typ = s
	case string:
		typ = x
	default:
		return shapeOther
	}
	switch strings.ToLower(strings.TrimSpace(typ)) {
	case "json_schema":
		return "json_schema"
	case "json_object":
		return "json_object"
	case "text":
		return "text"
	default:
		return shapeOther
	}
}

// jsonNumberValue extracts a float64 from a value only when the request
// carried a JSON number (json.Number under the prelude's UseNumber decoder;
// float64/int accepted for robustness). Strings and other types are never
// coerced — the field is then omitted from the log line.
func jsonNumberValue(v any) (float64, bool) {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return 0, false
		}
		return f, true
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	default:
		return 0, false
	}
}
