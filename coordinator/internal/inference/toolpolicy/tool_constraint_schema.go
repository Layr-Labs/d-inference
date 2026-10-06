package toolpolicy

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"

	jsonvalue "github.com/eigeninference/d-inference/coordinator/internal/inference/jsonvalue"
)

const (
	constrainedMaxArrayItems        = 16
	ConstrainedMaxGrammarComplexity = 50_000
	constrainedSchemaFixedCost      = 8
	constrainedNullableBranchCost   = 4
)

var constrainedStringDelimiters = []string{
	`<|"|>`,
	"<escape>",
	"<|tool_call>",
	"<tool_call|>",
	"<start_function_call>",
	"<end_function_call>",
}

func ValidateConstrainedSchema(raw any, root bool, depth int, path string) error {
	if depth > 16 {
		return UnsupportedToolConstraint(path + " exceeds maximum nesting depth 16")
	}
	schema, ok := raw.(map[string]any)
	if !ok {
		return InvalidToolConstraint(path+" must be a schema object", "tools")
	}
	// Normalization rewrites the allow-all `{}` / `true` schemas into a
	// render-safe marker shape that grammar modes compile as the free string
	// the original `{}` compiled to. Only that exact non-root shape is
	// accepted; any other marker-bearing schema fails closed. Mirrors the
	// Swift compiler and the Rust sidecar validator. (Production validates
	// the pre-normalization body, where the marker never legitimately
	// appears; this keeps re-validation of normalized bodies symmetric.)
	if marker, present := schema[OriginalBooleanSchemaKey]; present {
		if !root && marker == true && len(schema) == 2 && schema["type"] == "string" {
			return nil
		}
		return UnsupportedToolConstraint(path + " uses reserved schema metadata")
	}
	for key := range schema {
		switch key {
		case "type", "properties", "required", "additionalProperties", "items",
			"minItems", "maxItems", "nullable", "enum", "const", "description",
			"title", "default", "examples", "deprecated", "readOnly", "writeOnly":
		default:
			return UnsupportedToolConstraint(path + " uses " + key)
		}
	}
	kind, nullable, err := constrainedSchemaType(schema)
	if err != nil {
		return UnsupportedToolConstraint(path + ": " + err.Error())
	}
	if rawNullable, exists := schema["nullable"]; exists {
		flag, ok := rawNullable.(bool)
		if !ok {
			return InvalidToolConstraint(path+".nullable must be boolean", "tools")
		}
		nullable = nullable || flag
	}
	if root && (kind != "object" || nullable) {
		return InvalidToolConstraint(path+" must be a non-null object schema", "tools")
	}
	if err := validateConstrainedFiniteValues(schema, kind, nullable, path); err != nil {
		return err
	}
	switch kind {
	case "object":
		properties := map[string]any{}
		if rawProperties, exists := schema["properties"]; exists {
			var ok bool
			properties, ok = rawProperties.(map[string]any)
			if !ok {
				return InvalidToolConstraint(path+".properties must be an object", "tools")
			}
		}
		if len(properties) > 128 {
			return InvalidToolConstraint(path+" has more than 128 properties", "tools")
		}
		for name, child := range properties {
			if !toolFunctionNamePattern.MatchString(name) {
				return UnsupportedToolConstraint(
					path + " property names must match ^[a-zA-Z0-9_-]{1,64}$")
			}
			if err := ValidateConstrainedSchema(child, false, depth+1, path+".properties."+name); err != nil {
				return err
			}
		}
		if required, exists := schema["required"]; exists {
			values, ok := required.([]any)
			if !ok {
				return InvalidToolConstraint(path+".required must be an array", "tools")
			}
			seen := make(map[string]struct{}, len(values))
			for _, value := range values {
				name, ok := value.(string)
				if !ok {
					return InvalidToolConstraint(path+".required members must be strings", "tools")
				}
				if _, declared := properties[name]; !declared {
					return InvalidToolConstraint(path+".required contains an undeclared property", "tools")
				}
				if _, duplicate := seen[name]; duplicate {
					return InvalidToolConstraint(path+".required contains a duplicate property", "tools")
				}
				seen[name] = struct{}{}
			}
		}
		if additional, exists := schema["additionalProperties"]; exists {
			if _, ok := additional.(bool); !ok {
				return UnsupportedToolConstraint(path + ".additionalProperties must be boolean")
			}
		}
	case "array":
		items, exists := schema["items"]
		if !exists {
			return UnsupportedToolConstraint(path + " array requires a single items schema")
		}
		if err := ValidateConstrainedSchema(items, false, depth+1, path+".items"); err != nil {
			return err
		}
		rawMinItems, hasMinItems := schema["minItems"]
		if hasMinItems && rawMinItems == nil {
			return InvalidToolConstraint(path+".minItems must be a nonnegative integer", "tools")
		}
		minItems, err := jsonvalue.ConstrainedNonnegativeInt(rawMinItems, 0)
		if err != nil {
			return InvalidToolConstraint(path+".minItems must be a nonnegative integer", "tools")
		}
		rawMaxItems, hasMaxItems := schema["maxItems"]
		if hasMaxItems && rawMaxItems == nil {
			return InvalidToolConstraint(path+".maxItems must be a nonnegative integer", "tools")
		}
		maxItems, hasMax, err := jsonvalue.ConstrainedOptionalInt(rawMaxItems)
		if err != nil {
			return InvalidToolConstraint(path+".maxItems must be a nonnegative integer", "tools")
		}
		if minItems > constrainedMaxArrayItems ||
			(hasMax && (maxItems > constrainedMaxArrayItems || maxItems < minItems)) {
			return UnsupportedToolConstraint(path + " array bounds must be within 0...16")
		}
	case "string", "boolean", "integer", "number", "null":
	default:
		return UnsupportedToolConstraint(path + " has unsupported type " + kind)
	}
	return nil
}

func ConstrainedSchemaGrammarCost(raw any) int {
	schema, ok := raw.(map[string]any)
	if !ok {
		return ConstrainedMaxGrammarComplexity + 1
	}
	kind, nullable, err := constrainedSchemaType(schema)
	if err != nil {
		return ConstrainedMaxGrammarComplexity + 1
	}
	if rawNullable, exists := schema["nullable"]; exists {
		flag, ok := rawNullable.(bool)
		if !ok {
			return ConstrainedMaxGrammarComplexity + 1
		}
		nullable = nullable || flag
	}
	values, finite := constrainedSchemaFiniteValues(schema)
	// JSON Schema applies type and enum/const conjunctively: a nullable type
	// admits null only when the finite value set itself contains null, so the
	// grammar builds no null branch (and charges no branch cost) otherwise.
	// Mirrors the Swift compiler's effective-nullable rule.
	if finite && !constrainedValuesContainNull(values) {
		nullable = false
	}
	baseCost := constrainedSchemaFixedCost
	if nullable {
		baseCost = ConstrainedGrammarAdd(baseCost, constrainedNullableBranchCost)
	}
	payloadCost := 0
	switch kind {
	case "object":
		payloadCost = 2
		properties, _ := schema["properties"].(map[string]any)
		for name, child := range properties {
			payloadCost = ConstrainedGrammarAdd(
				payloadCost, len([]byte(name))+2+ConstrainedSchemaGrammarCost(child))
		}
	case "array":
		count := constrainedMaxArrayItems
		if maximum, present, parseErr := jsonvalue.ConstrainedOptionalInt(schema["maxItems"]); parseErr == nil && present {
			count = maximum
		}
		itemCost := ConstrainedSchemaGrammarCost(schema["items"])
		payloadCost = ConstrainedGrammarAdd(
			2, constrainedGrammarMultiply(itemCost+1, count))
	case "string":
		if !finite {
			payloadCost = 16
		} else {
			for _, value := range values {
				if text, ok := value.(string); ok {
					payloadCost = ConstrainedGrammarAdd(
						payloadCost, len([]byte(text))+10)
				}
			}
		}
	case "boolean":
		if !finite {
			payloadCost = 10
		} else {
			count := 0
			for _, value := range values {
				if _, ok := value.(bool); ok {
					count++
				}
			}
			payloadCost = constrainedGrammarMultiply(count, 5)
		}
	case "integer", "number":
		if !finite {
			if kind == "integer" {
				payloadCost = 20
			} else {
				payloadCost = 40
			}
		} else {
			for _, value := range values {
				if number, ok := value.(json.Number); ok {
					payloadCost = ConstrainedGrammarAdd(
						payloadCost, len(number.String()))
				}
			}
		}
	case "null":
		payloadCost = 4
	default:
		return ConstrainedMaxGrammarComplexity + 1
	}
	return ConstrainedGrammarAdd(baseCost, payloadCost)
}

func constrainedSchemaFiniteValues(schema map[string]any) ([]any, bool) {
	if constant, ok := schema["const"]; ok {
		return []any{constant}, true
	}
	values, ok := schema["enum"].([]any)
	return values, ok
}

func constrainedValuesContainNull(values []any) bool {
	for _, value := range values {
		if value == nil {
			return true
		}
	}
	return false
}

func ConstrainedGrammarAdd(lhs, rhs int) int {
	if lhs > ConstrainedMaxGrammarComplexity ||
		rhs > ConstrainedMaxGrammarComplexity ||
		lhs > ConstrainedMaxGrammarComplexity-rhs {
		return ConstrainedMaxGrammarComplexity + 1
	}
	return lhs + rhs
}

func constrainedGrammarMultiply(lhs, rhs int) int {
	if lhs < 0 || rhs < 0 ||
		(rhs != 0 && lhs > ConstrainedMaxGrammarComplexity/rhs) {
		return ConstrainedMaxGrammarComplexity + 1
	}
	product := lhs * rhs
	if product > ConstrainedMaxGrammarComplexity {
		return ConstrainedMaxGrammarComplexity + 1
	}
	return product
}

func validateConstrainedFiniteValues(
	schema map[string]any,
	kind string,
	nullable bool,
	path string,
) error {
	constant, hasConstant := schema["const"]
	rawEnum, hasEnum := schema["enum"]
	if hasConstant && hasEnum {
		return InvalidToolConstraint(path+" cannot contain both const and enum", "tools")
	}
	var values []any
	if hasConstant {
		values = []any{constant}
	} else if hasEnum {
		var ok bool
		values, ok = rawEnum.([]any)
		if !ok || len(values) == 0 || len(values) > 128 {
			return InvalidToolConstraint(path+".enum must contain 1...128 values", "tools")
		}
	} else {
		return nil
	}
	if kind == "object" || kind == "array" || kind == "number" {
		return UnsupportedToolConstraint(path + " uses enum/const on " + kind)
	}
	for _, value := range values {
		if value == nil && nullable {
			continue
		}
		if kind == "string" {
			if text, ok := value.(string); ok {
				for _, marker := range constrainedStringDelimiters {
					if strings.Contains(text, marker) {
						return UnsupportedToolConstraint(
							path + " string enum/const contains a Gemma parser delimiter")
					}
				}
			}
		}
		if !constrainedValueMatchesType(value, kind) {
			return InvalidToolConstraint(
				path+" enum/const does not match type "+kind, "tools")
		}
	}
	return nil
}

func constrainedValueMatchesType(value any, kind string) bool {
	switch kind {
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "integer":
		number, ok := value.(json.Number)
		if !ok {
			return false
		}
		return jsonvalue.ConstrainedJSONInteger(number)
	case "number":
		number, ok := value.(json.Number)
		if !ok {
			return false
		}
		parsed, err := number.Float64()
		return err == nil &&
			!math.IsInf(parsed, 0) &&
			!math.IsNaN(parsed)
	case "null":
		return value == nil
	default:
		return false
	}
}

func constrainedSchemaType(schema map[string]any) (string, bool, error) {
	raw := schema["type"]
	if raw == nil {
		if schema["properties"] != nil || schema["additionalProperties"] != nil {
			return "object", false, nil
		}
		if schema["items"] != nil {
			return "array", false, nil
		}
		return "string", false, nil
	}
	if value, ok := raw.(string); ok {
		return strings.ToLower(value), false, nil
	}
	values, ok := raw.([]any)
	if !ok {
		return "", false, fmt.Errorf("type must be a string")
	}
	var nonNull string
	sawNull := false
	for _, rawValue := range values {
		value, ok := rawValue.(string)
		if !ok {
			return "", false, fmt.Errorf("type members must be strings")
		}
		if strings.EqualFold(value, "null") {
			sawNull = true
		} else if nonNull == "" {
			nonNull = strings.ToLower(value)
		} else {
			return "", false, fmt.Errorf("only one type plus null is supported")
		}
	}
	if !sawNull || nonNull == "" {
		return "", false, fmt.Errorf("only one type plus null is supported")
	}
	return nonNull, true, nil
}
