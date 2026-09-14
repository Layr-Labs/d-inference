package toolpolicy

import (
	"bytes"
	"encoding/json"
	"fmt"
)

const (
	maxConstrainedStopSequences = 4
	maxConstrainedStopBytes     = 256
)

// ValidateBytes validates tool policy in a JSON request body, decoding numbers
// with json.Decoder.UseNumber. The body must contain the caller's original tools,
// before normalization; endpoint lowering belongs to the caller.
func ValidateBytes(body []byte) (Policy, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil {
		return Policy{},
			invalidToolConstraint("invalid request body", "")
	}
	return ValidateParsed(root, nil)
}

// ValidateParsed validates tool_choice, parallel_tool_calls, parser, stops, tools,
// and history without decoding the body again. Pass the originalTools returned
// by NormalizeParsed so validation judges the caller's schemas and detects forged
// normalization markers. Pass nil when root has not been normalized.
// Numeric values must retain json.Number, as with json.Decoder.UseNumber.
func ValidateParsed(root map[string]any, originalTools []any) (Policy, error) {
	root = constraintView(root, originalTools)
	mode, selected, err := parseToolChoice(root["tool_choice"])
	if err != nil {
		return Policy{}, err
	}
	policy := Policy{
		Mode: mode, Name: selected, Parallel: true,
	}
	if parallel, exists := root["parallel_tool_calls"]; exists && parallel != nil {
		value, ok := parallel.(bool)
		if !ok {
			return policy,
				invalidToolConstraint("parallel_tool_calls must be boolean", "parallel_tool_calls")
		}
		policy.Parallel = value
	}

	enforceSchema := mode == Required || mode == Named
	if mode.RequiresInferenceConstraint() {
		if parser, exists := root["tool_call_parser"]; exists && parser != nil {
			name, ok := parser.(string)
			if !ok || !supportsInferenceEnforcedToolChoice(name) {
				return policy, invalidToolConstraint(
					"inference-enforced tool_choice requires a supported Gemma or Qwen tool_call_parser",
					"tool_call_parser")
			}
		}
	}
	if mode == Required || mode == Named {
		if err := validateConstrainedStops(root["stop"]); err != nil {
			return policy, err
		}
	}
	// The constrained path already sees the reserved marker through
	// validateConstrainedSchema, which enforces its canonical form; the
	// standalone forgery walk therefore covers exactly the modes that path
	// skips — auto and none.
	tools, err := validateDeclaredTools(
		root["tools"], enforceSchema, selected, !enforceSchema)
	if err != nil {
		return policy, err
	}
	if mode == Required && len(tools) == 0 {
		return policy, invalidToolConstraint(
			"tool_choice 'required' needs at least one declared tool", "tool_choice")
	}
	if mode == Named {
		if _, ok := tools[selected]; !ok {
			return policy, invalidToolConstraint(
				"tool_choice names an undeclared function", "tool_choice")
		}
	}
	if err := validateToolHistory(root["messages"]); err != nil {
		return policy, err
	}
	return policy, nil
}

func validateConstrainedStops(raw any) error {
	if raw == nil {
		return nil
	}
	var stops []any
	if text, ok := raw.(string); ok {
		stops = []any{text}
	} else {
		var ok bool
		stops, ok = raw.([]any)
		if !ok {
			return invalidToolConstraint(
				"stop must be a string or an array of strings", "stop")
		}
	}
	nonempty := 0
	for _, rawStop := range stops {
		stop, ok := rawStop.(string)
		if !ok {
			return invalidToolConstraint(
				"stop entries must be strings", "stop")
		}
		if stop == "" {
			continue
		}
		nonempty++
		if len([]byte(stop)) > maxConstrainedStopBytes {
			return invalidToolConstraint(
				fmt.Sprintf(
					"inference-enforced tool_choice stop sequences are limited to %d UTF-8 bytes",
					maxConstrainedStopBytes),
				"stop")
		}
	}
	if nonempty > maxConstrainedStopSequences {
		return invalidToolConstraint(
			fmt.Sprintf(
				"inference-enforced tool_choice supports at most %d non-empty stop sequences",
				maxConstrainedStopSequences),
			"stop")
	}
	return nil
}

func parseToolChoice(raw any) (Mode, string, error) {
	if raw == nil {
		return Auto, "", nil
	}
	if value, ok := raw.(string); ok {
		switch value {
		case "auto":
			return Auto, "", nil
		case "none":
			return None, "", nil
		case "required":
			return Required, "", nil
		default:
			return "", "", invalidToolConstraint(
				"tool_choice must be auto, none, required, or a named function", "tool_choice")
		}
	}
	object, ok := raw.(map[string]any)
	if !ok {
		return "", "", invalidToolConstraint(
			"tool_choice must be auto, none, required, or a named function", "tool_choice")
	}
	switch object["type"] {
	case "auto":
		return Auto, "", nil
	case "none":
		return None, "", nil
	case "required":
		return Required, "", nil
	case "function":
	default:
		return "", "", invalidToolConstraint(
			"tool_choice must be auto, none, required, or a named function", "tool_choice")
	}
	topLevelName, _ := object["name"].(string)
	nestedName := ""
	if function, ok := object["function"].(map[string]any); ok {
		if nested, ok := function["name"].(string); ok {
			nestedName = nested
		}
	}
	if topLevelName != "" && nestedName != "" && topLevelName != nestedName {
		return "", "", invalidToolConstraint(
			"tool_choice contains conflicting function names", "tool_choice")
	}
	name := topLevelName
	if name == "" {
		name = nestedName
	}
	if !toolFunctionNamePattern.MatchString(name) {
		return "", "", invalidToolConstraint(
			"tool_choice function name must match ^[a-zA-Z0-9_-]{1,64}$", "tool_choice")
	}
	return Named, name, nil
}
