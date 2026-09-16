package toolpolicy

import (
	"encoding/json"
	"slices"
	"strings"
)

// typeStringMembers extracts the string members of an array-form `type`
// value. Any other shape (number, bool, object, null) yields no members,
// pushing the collapse to structural inference.
func typeStringMembers(t any) []string {
	arr, ok := t.([]any)
	if !ok {
		return nil
	}
	members := make([]string, 0, len(arr))
	for _, m := range arr {
		if s, ok := m.(string); ok {
			members = append(members, strings.ToLower(s))
		}
	}
	return members
}

// distinctConcreteTypeMembers returns the distinct non-"null" members of an
// array-form `type` in first-appearance order. Members arrive lowercased from
// typeStringMembers, so distinctness is case-insensitive by construction.
func distinctConcreteTypeMembers(members []string) []string {
	concrete := make([]string, 0, len(members))
	for _, m := range members {
		if m != "null" && !slices.Contains(concrete, m) {
			concrete = append(concrete, m)
		}
	}
	return concrete
}

// hasSchemaUnionKey reports whether the node carries any combinator key
// (anyOf/oneOf/allOf), regardless of the value's shape.
func hasSchemaUnionKey(dict map[string]any) bool {
	for _, key := range schemaUnionKeys {
		if _, ok := dict[key]; ok {
			return true
		}
	}
	return false
}

// collapsedType collapses a non-string `type` value (pre-extracted string
// members of the array form) to one renderable string: the first concrete
// (non-"null") member, the lone "null" when that is all the array declares,
// else fall back to structural inference.
func collapsedType(members []string, dict map[string]any) string {
	for _, m := range members {
		if m != "null" {
			return m
		}
	}
	if len(members) > 0 {
		return members[0]
	}
	return inferredType(dict)
}

// looksLikeSchemaNode reports whether the map carries any JSON-Schema marker
// key. Only NON-positional nodes (the tool schema roots) need this evidence
// to receive a defaulted `type` — schema-positional values are schemas by
// definition (see injectTypes).
func looksLikeSchemaNode(dict map[string]any) bool {
	for _, key := range []string{
		"properties", "patternProperties", "items", "prefixItems",
		"additionalProperties", "enum", "description", "anyOf", "oneOf", "allOf",
	} {
		if _, ok := dict[key]; ok {
			return true
		}
	}
	return false
}

// inferredType is the structural default for a schema node's `type`: object
// when it has properties / patternProperties / additionalProperties, array
// when it has items / prefixItems, a union member's type when it is an
// anyOf/oneOf/allOf (skipping "null" — mislabelling a union as a string would
// be wrong), the single concrete type of its const/enum values when the node
// declares finite values (a typeless `{"const":1}` accepts 1, so the injected
// render type must be "number", not "string" — the string default would make
// every schema-valid emission fail post-generation validation), otherwise
// string.
func inferredType(dict map[string]any) string {
	for _, key := range []string{"properties", "patternProperties", "additionalProperties"} {
		if _, ok := dict[key]; ok {
			return "object"
		}
	}
	for _, key := range []string{"items", "prefixItems"} {
		if _, ok := dict[key]; ok {
			return "array"
		}
	}
	if t, ok := unionMemberType(dict); ok {
		return t
	}
	if concrete, sawNull, ok := finiteValueTypes(dict); ok {
		if len(concrete) == 1 {
			for name := range concrete {
				return name
			}
		}
		if len(concrete) == 0 && sawNull {
			return "null"
		}
	}
	if families := assertionFamilyTypes(dict); len(families) == 1 {
		for family := range families {
			return family
		}
	}
	return "string"
}

// assertionFamilyByKeyword maps type-scoped JSON-Schema assertion keywords to
// the instance type they constrain. A typeless `{"minimum":5}` accepts 6, so
// the injected render type must be "number" — the string default would make
// every schema-valid numeric emission fail post-generation validation.
var assertionFamilyByKeyword = map[string]string{
	"minimum":          "number",
	"maximum":          "number",
	"exclusiveMinimum": "number",
	"exclusiveMaximum": "number",
	"multipleOf":       "number",
	"minLength":        "string",
	"maxLength":        "string",
	"pattern":          "string",
	"minItems":         "array",
	"maxItems":         "array",
	"uniqueItems":      "array",
	"contains":         "array",
	"minContains":      "array",
	"maxContains":      "array",
	"minProperties":    "object",
	"maxProperties":    "object",
	"required":         "object",
}

// assertionFamilyTypes reports the instance-type families implied by a node's
// type-scoped assertion keywords.
func assertionFamilyTypes(dict map[string]any) map[string]struct{} {
	families := make(map[string]struct{}, 2)
	for keyword, family := range assertionFamilyByKeyword {
		if _, ok := dict[keyword]; ok {
			families[family] = struct{}{}
		}
	}
	return families
}

// finiteValueTypes reports the JSON type names of a node's const/enum values:
// the set of concrete (non-null) member types plus whether null appears.
// ok is false when the node carries no const and no non-empty enum array.
func finiteValueTypes(dict map[string]any) (concrete map[string]struct{}, sawNull bool, ok bool) {
	var values []any
	if constant, present := dict["const"]; present {
		values = []any{constant}
	} else if members, isArray := dict["enum"].([]any); isArray && len(members) > 0 {
		values = members
	} else {
		return nil, false, false
	}
	concrete = make(map[string]struct{}, 2)
	for _, value := range values {
		name := jsonValueTypeName(value)
		if name == "null" {
			sawNull = true
			continue
		}
		concrete[name] = struct{}{}
	}
	return concrete, sawNull, true
}

// jsonValueTypeName maps a decoded JSON value to its JSON-Schema type name.
// Integral and fractional numbers both report "number" — "number" admits
// integers under raw validation, so the coarser name is always safe.
func jsonValueTypeName(value any) string {
	switch value.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case json.Number, float64:
		return "number"
	case string:
		return "string"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return "string"
	}
}

// unionMemberType derives a representative `type` for a union node from the
// first member that declares a concrete, non-"null" type. The second return
// is false when none is found.
func unionMemberType(dict map[string]any) (string, bool) {
	for _, key := range schemaUnionKeys {
		variants, ok := dict[key].([]any)
		if !ok {
			continue
		}
		for _, variant := range variants {
			v, ok := variant.(map[string]any)
			if !ok {
				continue
			}
			// Marker types exist only to keep the Gemma template renderable;
			// they carry no instance-type evidence for their parent.
			if _, marker := renderMarkerBoolean(v); marker {
				continue
			}
			if t, ok := v["type"].(string); ok && t != "null" {
				return t, true
			}
		}
	}
	return "", false
}
