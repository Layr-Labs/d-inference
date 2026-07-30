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
	// Recursion bound for the reserved-metadata walk. Exceeding it stops the
	// descent without rejecting: the walk is a forgery guard, not a schema
	// feasibility check, so a legitimately deep schema must still be accepted.
	maxReservedMetadataDepth = 32
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
	// The constrained path already sees the reserved marker through
	// validateConstrainedSchema, which enforces its canonical form; the
	// standalone forgery walk therefore covers exactly the modes that path
	// skips — auto and none.
	tools, err := validateDeclaredTools(
		root["tools"], enforceSchema, selected, !enforceSchema)
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

// requiresGrammar reports whether the mode needs a sampler-level grammar, and
// therefore a provider advertising inference-time tool_choice enforcement.
// `none` is deliberately excluded: it is honored by hiding tools from the
// rendered prompt and rejecting any call the model emits anyway after
// generation, so it needs no grammar and must not be fenced to the
// Gemma-class constrained provider pool.
func (m toolChoiceMode) requiresGrammar() bool {
	return m == toolChoiceRequired || m == toolChoiceNamed
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
	checkReservedMetadata bool,
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
			// Auto/none preserve the provider's established compatibility
			// behavior (InboundChatNormalization.isRepresentableTool):
			// hosted/custom tools with no function dict and no top-level
			// name are dropped provider-side, so they forward untouched;
			// representable alternate spellings (top-level name, misc
			// type + function dict) render provider-side and get the same
			// name/duplicate/pattern validation function tools get, just
			// via their own schema home. Required/named enforcement cannot
			// silently drop a requested tool because doing so would weaken
			// the caller's constraint.
			if !enforceSchema {
				name, parameters, representable := representableToolSpelling(tool)
				if !representable {
					continue
				}
				if !toolFunctionNamePattern.MatchString(name) {
					return nil, invalidToolConstraint(
						"tool function names must match ^[a-zA-Z0-9_-]{1,64}$",
						fmt.Sprintf("tools[%d].name", index))
				}
				if _, duplicate := tools[name]; duplicate {
					return nil, invalidToolConstraint("tool function names must be unique", "tools")
				}
				if checkReservedMetadata && parameters != nil {
					if err := rejectReservedSchemaMetadata(parameters, 0); err != nil {
						return nil, err
					}
				}
				tools[name] = map[string]any{"name": name, "parameters": parameters}
				continue
			}
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
		if checkReservedMetadata {
			if err := rejectReservedSchemaMetadata(parameters, 0); err != nil {
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

// representableToolSpelling mirrors the provider's
// InboundChatNormalization.isRepresentableTool for non-`type:function`
// entries: an object function dict or a top-level name string makes the tool
// renderable provider-side; anything else is dropped there. The returned
// parameters value is the schema home the entry actually carries
// (function.parameters, top-level parameters, or input_schema).
func representableToolSpelling(tool map[string]any) (name string, parameters any, ok bool) {
	if function, isObject := tool["function"].(map[string]any); isObject {
		name, _ = function["name"].(string)
		return name, function["parameters"], true
	}
	if topLevel, isString := tool["name"].(string); isString {
		parameters = tool["parameters"]
		if parameters == nil {
			parameters = tool["input_schema"]
		}
		return topLevel, parameters, true
	}
	return "", nil, false
}

// rejectReservedSchemaMetadata walks a declared tool schema looking for the
// coordinator's own normalization marker. NormalizeToolSchemas stamps
// originalBooleanSchemaKey onto schemas it rewrites so the provider can
// restore the original allow/deny-all semantics after generation; a caller
// that plants the key itself would forge that decision. Validation runs on
// the pre-normalization body (consumer.go's originalRawBody), so any
// occurrence here is client-supplied and must be refused.
//
// This is deliberately NOT a grammar-feasibility check. Auto and none never
// compile a sampler grammar — their tool calls are checked post-generation by
// the provider's JSON-Schema validator, which handles anyOf/oneOf/$ref/
// pattern/if-then natively — so every other JSON-Schema construct passes
// through untouched.
func rejectReservedSchemaMetadata(schema any, depth int) error {
	if depth > maxReservedMetadataDepth {
		return nil
	}
	switch value := schema.(type) {
	case []any:
		for _, child := range value {
			if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
				return err
			}
		}
	case map[string]any:
		if _, forged := value[originalBooleanSchemaKey]; forged {
			return invalidToolConstraint(
				"tool schema contains reserved internal metadata", "tools")
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
			if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
				return err
			}
		}
		for _, key := range []string{"allOf", "anyOf", "oneOf", "prefixItems"} {
			children, ok := value[key].([]any)
			if !ok {
				continue
			}
			for _, child := range children {
				if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
					return err
				}
			}
		}
		// `items` is a schema in draft 2020-12 and a tuple in draft-07. The
		// tuple array is a container, not a schema node, so it must not
		// consume a level of the depth budget the way a nested schema does.
		if items, exists := value["items"]; exists {
			if tuple, ok := items.([]any); ok {
				for _, child := range tuple {
					if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
						return err
					}
				}
			} else if err := rejectReservedSchemaMetadata(items, depth+1); err != nil {
				return err
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
				if err := rejectReservedSchemaMetadata(child, depth+1); err != nil {
					return err
				}
			}
		}
	}
	return nil
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
