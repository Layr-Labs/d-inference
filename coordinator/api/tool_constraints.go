package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"
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
	maxSafeAutoPatternBytes     = 128
	maxSafeAutoPatternCount     = 32
	maxAutoPatternDepth         = 32
)

type validatedToolConstraintPolicy struct {
	mode     toolChoiceMode
	name     string
	parallel bool
}

func validateToolConstraintRequest(body []byte) (toolChoiceMode, error) {
	policy, err := validateToolConstraintPolicy(body)
	return policy.mode, err
}

func validateToolConstraintPolicy(body []byte) (validatedToolConstraintPolicy, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil {
		return validatedToolConstraintPolicy{},
			invalidToolConstraint("invalid request body", "")
	}
	mode, selected, err := parseToolChoice(root["tool_choice"])
	if err != nil {
		return validatedToolConstraintPolicy{}, err
	}
	policy := validatedToolConstraintPolicy{
		mode: mode, name: selected, parallel: true,
	}
	if parallel, exists := root["parallel_tool_calls"]; exists && parallel != nil {
		value, ok := parallel.(bool)
		if !ok {
			return policy,
				invalidToolConstraint("parallel_tool_calls must be boolean", "parallel_tool_calls")
		}
		policy.parallel = value
	}

	enforceSchema := mode == toolChoiceRequired || mode == toolChoiceNamed
	if mode.requiresGrammar() {
		if parser, exists := root["tool_call_parser"]; exists && parser != nil {
			if parser != "gemma" {
				return policy, invalidToolConstraint(
					"inference-enforced Gemma tool_choice requires tool_call_parser 'gemma'",
					"tool_call_parser")
			}
		}
	}
	if mode == toolChoiceRequired || mode == toolChoiceNamed {
		if err := validateConstrainedStops(root["stop"]); err != nil {
			return policy, err
		}
	}
	tools, err := validateDeclaredTools(
		root["tools"], enforceSchema, selected, mode == toolChoiceAuto)
	if err != nil {
		return policy, err
	}
	if mode == toolChoiceRequired && len(tools) == 0 {
		return policy, invalidToolConstraint(
			"tool_choice 'required' needs at least one declared tool", "tool_choice")
	}
	if mode == toolChoiceNamed {
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

func validateDeclaredTools(
	raw any,
	enforceSchema bool,
	selected string,
	validateAutoPatterns bool,
) (map[string]map[string]any, error) {
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
		parameters := function["parameters"]
		if parameters == nil {
			parameters = map[string]any{"type": "object"}
		}
		if validateAutoPatterns {
			if err := validateAutoSchemaPatterns(parameters, 0); err != nil {
				return nil, err
			}
		}
		if enforceSchema && (selected == "" || name == selected) {
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

func validateAutoSchemaPatterns(schema any, depth int) error {
	if depth > maxAutoPatternDepth {
		return unsupportedToolConstraint("auto tool schema exceeds pattern-validation depth")
	}
	switch value := schema.(type) {
	case []any:
		for _, child := range value {
			if err := validateAutoSchemaPatterns(child, depth+1); err != nil {
				return err
			}
		}
	case map[string]any:
		if _, forged := value[originalBooleanSchemaKey]; forged {
			return invalidToolConstraint(
				"tool schema contains reserved internal metadata", "tools")
		}
		if _, hasReference := value["$ref"]; hasReference {
			return unsupportedToolConstraint(
				"auto tool schemas do not support $ref")
		}
		for _, keyword := range []string{"if", "then", "else"} {
			if _, conditional := value[keyword]; conditional {
				return unsupportedToolConstraint(
					"auto tool schemas do not support conditional assertions")
			}
		}
		for _, keyword := range []string{
			"dependentSchemas", "dependentRequired", "dependencies", "propertyNames",
			"unevaluatedItems", "unevaluatedProperties",
		} {
			if _, unsupported := value[keyword]; unsupported {
				return unsupportedToolConstraint(
					"auto tool schemas do not support dependency, property-name, or unevaluated assertions")
			}
		}
		// A typeless node with mixed-type const/enum values (e.g.
		// `{"enum":["a",1]}`) or assertions spanning multiple type families
		// (e.g. `{"minimum":5,"minLength":2}`) has no single renderable type:
		// normalization would have to pick one and silently break the rest
		// post-generation. Fail early instead, mirroring the multi-type
		// union policy.
		if _, hasType := value["type"]; !hasType {
			if concrete, _, ok := finiteValueTypes(value); ok {
				if len(concrete) > 1 {
					return unsupportedToolConstraint(
						"auto tool schemas require an explicit type for mixed-type enum/const values")
				}
			} else if typelessAssertionFamiliesAmbiguous(value) {
				return unsupportedToolConstraint(
					"auto tool schemas require an explicit type for mixed-family assertions")
			}
		}
		if rawTypes, ok := value["type"].([]any); ok {
			concrete := make(map[string]struct{}, len(rawTypes))
			for _, rawType := range rawTypes {
				member, ok := rawType.(string)
				if !ok {
					return unsupportedToolConstraint(
						"auto tool schema type arrays must contain strings")
				}
				member = strings.ToLower(member)
				if member != "null" {
					concrete[member] = struct{}{}
				}
			}
			if len(concrete) > 1 {
				return unsupportedToolConstraint(
					"auto tool schemas support only one concrete type plus null")
			}
		}
		for _, keyword := range []string{"anyOf", "oneOf"} {
			variants, ok := value[keyword].([]any)
			if !ok {
				continue
			}
			concrete := make(map[string]struct{})
			for _, rawVariant := range variants {
				variant, ok := rawVariant.(map[string]any)
				if !ok {
					return unsupportedToolConstraint(
						"auto tool schema union members must be objects")
				}
				members, err := autoConcreteSchemaTypes(variant["type"])
				if err != nil {
					return unsupportedToolConstraint(
						"auto tool schema union members require an explicit type")
				}
				for member := range members {
					concrete[member] = struct{}{}
				}
			}
			if len(concrete) > 1 {
				return unsupportedToolConstraint(
					"auto tool schemas do not support multi-type anyOf/oneOf unions")
			}
		}
		if raw, exists := value["pattern"]; exists {
			pattern, ok := raw.(string)
			if !ok || !safeAutoSchemaPattern(pattern) {
				return unsupportedToolConstraint(
					"auto tool schemas support only bounded literal pattern and patternProperties assertions")
			}
		}
		if raw, exists := value["patternProperties"]; exists {
			patterns, ok := raw.(map[string]any)
			if !ok {
				return unsupportedToolConstraint(
					"auto tool schema patternProperties must be an object")
			}
			if len(patterns) > maxSafeAutoPatternCount {
				return unsupportedToolConstraint(
					"auto tool schema has too many patternProperties assertions")
			}
			for pattern := range patterns {
				if !safeAutoSchemaPattern(pattern) {
					return unsupportedToolConstraint(
						"auto tool schemas support only bounded literal pattern and patternProperties assertions")
				}
			}
		}
		for _, key := range []string{
			"additionalProperties", "additionalItems", "contains", "contentSchema",
			"if", "then", "else", "not", "propertyNames",
			"unevaluatedItems", "unevaluatedProperties",
		} {
			child, exists := value[key]
			if !exists {
				continue
			}
			if err := validateAutoSchemaPatterns(child, depth+1); err != nil {
				return err
			}
		}
		for _, key := range []string{"allOf", "anyOf", "oneOf", "prefixItems"} {
			children, ok := value[key].([]any)
			if !ok {
				continue
			}
			for _, child := range children {
				if err := validateAutoSchemaPatterns(child, depth+1); err != nil {
					return err
				}
			}
		}
		if items, exists := value["items"]; exists {
			if tuple, ok := items.([]any); ok {
				for _, child := range tuple {
					if err := validateAutoSchemaPatterns(child, depth+1); err != nil {
						return err
					}
				}
			} else {
				if err := validateAutoSchemaPatterns(items, depth+1); err != nil {
					return err
				}
			}
		}
		for _, key := range []string{
			"properties", "patternProperties", "dependentSchemas",
			"dependencies", "definitions", "$defs",
		} {
			children, ok := value[key].(map[string]any)
			if !ok {
				continue
			}
			for _, child := range children {
				if err := validateAutoSchemaPatterns(child, depth+1); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func autoConcreteSchemaTypes(raw any) (map[string]struct{}, error) {
	concrete := make(map[string]struct{})
	switch value := raw.(type) {
	case string:
		if member := strings.ToLower(value); member != "null" {
			concrete[member] = struct{}{}
		}
	case []any:
		for _, rawMember := range value {
			member, ok := rawMember.(string)
			if !ok {
				return nil, fmt.Errorf("schema type member is not a string")
			}
			if member = strings.ToLower(member); member != "null" {
				concrete[member] = struct{}{}
			}
		}
	default:
		return nil, fmt.Errorf("schema type is missing")
	}
	return concrete, nil
}

func safeAutoSchemaPattern(pattern string) bool {
	if len([]byte(pattern)) > maxSafeAutoPatternBytes {
		return false
	}
	literal := pattern
	literal = strings.TrimPrefix(literal, "^")
	literal = strings.TrimSuffix(literal, "$")
	return !strings.ContainsAny(literal, `\.^$|?*+()[]{}`)
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
