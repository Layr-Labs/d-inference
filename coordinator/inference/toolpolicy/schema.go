package toolpolicy

import (
	"fmt"
	"strings"
)

func validateConstrainedSchema(raw any, root bool, depth int, path string) error {
	if depth > 16 {
		return unsupportedToolConstraint(path + " exceeds maximum nesting depth 16")
	}
	schema, ok := raw.(map[string]any)
	if !ok {
		return invalidToolConstraint(path+" must be a schema object", "tools")
	}
	// Normalization rewrites the allow-all `{}` / `true` schemas into a
	// render-safe marker shape that grammar modes compile as the free string
	// the original `{}` compiled to. Only that exact non-root shape is
	// accepted; any other marker-bearing schema fails closed. Mirrors the
	// Swift compiler and the Rust sidecar validator. (Production validates
	// the pre-normalization body, where the marker never legitimately
	// appears; this keeps re-validation of normalized bodies symmetric.)
	if marker, present := schema[originalBooleanSchemaKey]; present {
		if !root && marker == true && len(schema) == 2 && schema["type"] == "string" {
			return nil
		}
		return unsupportedToolConstraint(path + " uses reserved schema metadata")
	}
	for key := range schema {
		switch key {
		case "type", "properties", "required", "additionalProperties", "items",
			"minItems", "maxItems", "nullable", "enum", "const", "description",
			"title", "default", "examples", "deprecated", "readOnly", "writeOnly":
		default:
			return unsupportedToolConstraint(path + " uses " + key)
		}
	}
	kind, nullable, err := constrainedSchemaType(schema)
	if err != nil {
		return unsupportedToolConstraint(path + ": " + err.Error())
	}
	if rawNullable, exists := schema["nullable"]; exists {
		flag, ok := rawNullable.(bool)
		if !ok {
			return invalidToolConstraint(path+".nullable must be boolean", "tools")
		}
		nullable = nullable || flag
	}
	if root && (kind != "object" || nullable) {
		return invalidToolConstraint(path+" must be a non-null object schema", "tools")
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
				return invalidToolConstraint(path+".properties must be an object", "tools")
			}
		}
		if len(properties) > 128 {
			return invalidToolConstraint(path+" has more than 128 properties", "tools")
		}
		for name, child := range properties {
			if !toolFunctionNamePattern.MatchString(name) {
				return unsupportedToolConstraint(
					path + " property names must match ^[a-zA-Z0-9_-]{1,64}$")
			}
			if err := validateConstrainedSchema(child, false, depth+1, path+".properties."+name); err != nil {
				return err
			}
		}
		if required, exists := schema["required"]; exists {
			values, ok := required.([]any)
			if !ok {
				return invalidToolConstraint(path+".required must be an array", "tools")
			}
			seen := make(map[string]struct{}, len(values))
			for _, value := range values {
				name, ok := value.(string)
				if !ok {
					return invalidToolConstraint(path+".required members must be strings", "tools")
				}
				if _, declared := properties[name]; !declared {
					return invalidToolConstraint(path+".required contains an undeclared property", "tools")
				}
				if _, duplicate := seen[name]; duplicate {
					return invalidToolConstraint(path+".required contains a duplicate property", "tools")
				}
				seen[name] = struct{}{}
			}
		}
		if additional, exists := schema["additionalProperties"]; exists {
			if _, ok := additional.(bool); !ok {
				return unsupportedToolConstraint(path + ".additionalProperties must be boolean")
			}
		}
	case "array":
		items, exists := schema["items"]
		if !exists {
			return unsupportedToolConstraint(path + " array requires a single items schema")
		}
		if err := validateConstrainedSchema(items, false, depth+1, path+".items"); err != nil {
			return err
		}
		rawMinItems, hasMinItems := schema["minItems"]
		if hasMinItems && rawMinItems == nil {
			return invalidToolConstraint(path+".minItems must be a nonnegative integer", "tools")
		}
		minItems, err := constrainedNonnegativeInt(rawMinItems, 0)
		if err != nil {
			return invalidToolConstraint(path+".minItems must be a nonnegative integer", "tools")
		}
		rawMaxItems, hasMaxItems := schema["maxItems"]
		if hasMaxItems && rawMaxItems == nil {
			return invalidToolConstraint(path+".maxItems must be a nonnegative integer", "tools")
		}
		maxItems, hasMax, err := constrainedOptionalInt(rawMaxItems)
		if err != nil {
			return invalidToolConstraint(path+".maxItems must be a nonnegative integer", "tools")
		}
		if minItems > constrainedMaxArrayItems ||
			(hasMax && (maxItems > constrainedMaxArrayItems || maxItems < minItems)) {
			return unsupportedToolConstraint(path + " array bounds must be within 0...16")
		}
	case "string", "boolean", "integer", "number", "null":
	default:
		return unsupportedToolConstraint(path + " has unsupported type " + kind)
	}
	return nil
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
