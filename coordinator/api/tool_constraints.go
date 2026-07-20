package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
)

type toolChoiceMode string

const (
	toolChoiceAuto     toolChoiceMode = "auto"
	toolChoiceNone     toolChoiceMode = "none"
	toolChoiceRequired toolChoiceMode = "required"
	toolChoiceNamed    toolChoiceMode = "named"
)

type toolConstraintRequestError struct {
	status  int
	message string
	param   string
}

func (e *toolConstraintRequestError) Error() string { return e.message }

var toolFunctionNamePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

const (
	maxConstrainedStopSequences = 4
	maxConstrainedStopBytes     = 256
)

func validateToolConstraintRequest(body []byte) (toolChoiceMode, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil {
		return "", invalidToolConstraint("invalid request body", "")
	}
	mode, selected, err := parseToolChoice(root["tool_choice"])
	if err != nil {
		return "", err
	}
	if parallel, exists := root["parallel_tool_calls"]; exists && parallel != nil {
		if _, ok := parallel.(bool); !ok {
			return mode, invalidToolConstraint("parallel_tool_calls must be boolean", "parallel_tool_calls")
		}
	}

	enforceSchema := mode == toolChoiceRequired || mode == toolChoiceNamed
	if mode.requiresGrammar() {
		if parser, exists := root["tool_call_parser"]; exists && parser != nil {
			if parser != "gemma" {
				return mode, invalidToolConstraint(
					"inference-enforced Gemma tool_choice requires tool_call_parser 'gemma'",
					"tool_call_parser")
			}
		}
	}
	if mode == toolChoiceRequired || mode == toolChoiceNamed {
		if err := validateConstrainedStops(root["stop"]); err != nil {
			return mode, err
		}
	}
	tools, err := validateDeclaredTools(root["tools"], enforceSchema)
	if err != nil {
		return mode, err
	}
	if mode == toolChoiceRequired && len(tools) == 0 {
		return mode, invalidToolConstraint(
			"tool_choice 'required' needs at least one declared tool", "tool_choice")
	}
	if mode == toolChoiceNamed {
		if _, ok := tools[selected]; !ok {
			return mode, invalidToolConstraint(
				"tool_choice names an undeclared function", "tool_choice")
		}
	}
	if err := validateToolHistory(root["messages"]); err != nil {
		return mode, err
	}
	return mode, nil
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

func toolChoicePolicyFromBody(
	body []byte,
) (toolChoiceMode, string, bool, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil {
		return "", "", false, err
	}
	mode, name, err := parseToolChoice(root["tool_choice"])
	if err != nil {
		return "", "", false, err
	}
	parallel := true
	if raw, exists := root["parallel_tool_calls"]; exists && raw != nil {
		value, ok := raw.(bool)
		if !ok {
			return "", "", false, invalidToolConstraint(
				"parallel_tool_calls must be boolean", "parallel_tool_calls")
		}
		parallel = value
	}
	return mode, name, parallel, nil
}

func (m toolChoiceMode) requiresGrammar() bool {
	return m == toolChoiceNone || m == toolChoiceRequired || m == toolChoiceNamed
}

func parseToolChoice(raw any) (toolChoiceMode, string, error) {
	if raw == nil {
		return toolChoiceAuto, "", nil
	}
	if value, ok := raw.(string); ok {
		switch value {
		case "auto":
			return toolChoiceAuto, "", nil
		case "none":
			return toolChoiceNone, "", nil
		case "required":
			return toolChoiceRequired, "", nil
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
		return toolChoiceAuto, "", nil
	case "none":
		return toolChoiceNone, "", nil
	case "required":
		return toolChoiceRequired, "", nil
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
	return toolChoiceNamed, name, nil
}

func validateDeclaredTools(raw any, enforceSchema bool) (map[string]map[string]any, error) {
	if raw == nil {
		return nil, nil
	}
	values, ok := raw.([]any)
	if !ok {
		return nil, invalidToolConstraint("tools must be an array", "tools")
	}
	if len(values) > 64 {
		return nil, invalidToolConstraint("at most 64 tools are allowed", "tools")
	}
	tools := make(map[string]map[string]any, len(values))
	grammarComplexity := 0
	for index, rawTool := range values {
		tool, ok := rawTool.(map[string]any)
		if !ok || tool["type"] != "function" {
			return nil, invalidToolConstraint("only function tools are supported", fmt.Sprintf("tools[%d]", index))
		}
		function, ok := tool["function"].(map[string]any)
		if !ok {
			return nil, invalidToolConstraint("tools[].function is required", fmt.Sprintf("tools[%d].function", index))
		}
		name, _ := function["name"].(string)
		if !toolFunctionNamePattern.MatchString(name) {
			return nil, invalidToolConstraint(
				"tool function names must match ^[a-zA-Z0-9_-]{1,64}$",
				fmt.Sprintf("tools[%d].function.name", index))
		}
		if _, duplicate := tools[name]; duplicate {
			return nil, invalidToolConstraint("tool function names must be unique", "tools")
		}
		if enforceSchema {
			parameters := function["parameters"]
			if parameters == nil {
				parameters = map[string]any{"type": "object"}
			}
			if err := validateConstrainedSchema(parameters, true, 0, name+".parameters"); err != nil {
				return nil, err
			}
			grammarComplexity = constrainedGrammarAdd(
				grammarComplexity,
				len([]byte(name))+constrainedSchemaGrammarCost(parameters))
			if grammarComplexity > constrainedMaxGrammarComplexity {
				return nil, unsupportedToolConstraint(
					fmt.Sprintf(
						"combined tool grammar exceeds the %d-unit safety limit",
						constrainedMaxGrammarComplexity))
			}
		}
		tools[name] = function
	}
	return tools, nil
}

func invalidToolConstraint(message, param string) error {
	return &toolConstraintRequestError{
		status: http.StatusBadRequest, message: message, param: param,
	}
}

func unsupportedToolConstraint(message string) error {
	return &toolConstraintRequestError{
		status:  http.StatusUnprocessableEntity,
		message: message,
		param:   "tools",
	}
}

func (s *Server) recordToolConstraintMetric(mode toolChoiceMode, outcome string) {
	if mode == "" {
		mode = "invalid"
	}
	s.ddIncr("inference.tool_constraint", []string{
		"mode:" + string(mode),
		"outcome:" + outcome,
	})
}

func writeToolConstraintValidationError(
	w http.ResponseWriter,
	err error,
) {
	if typed, ok := err.(*toolConstraintRequestError); ok {
		options := []errorDetailOpt{}
		if typed.param != "" {
			options = append(options, withParam(typed.param))
		}
		writeJSON(w, typed.status, errorResponse(
			"invalid_request_error", typed.message, options...))
		return
	}
	writeJSON(w, http.StatusBadRequest, errorResponse(
		"invalid_request_error", err.Error()))
}
