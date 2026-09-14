package toolpolicy

import (
	"fmt"
	"regexp"
)

var toolFunctionNamePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

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
