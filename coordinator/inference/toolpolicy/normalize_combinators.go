package toolpolicy

import (
	"slices"
	"strings"
)

// schemaUnionKeys are the JSON-Schema combinators whose members are
// themselves schemas.
var schemaUnionKeys = []string{"anyOf", "oneOf", "allOf"}

var schemaAnnotationKeys = map[string]struct{}{
	"$anchor":     {},
	"$comment":    {},
	"$id":         {},
	"$schema":     {},
	"default":     {},
	"deprecated":  {},
	"description": {},
	"examples":    {},
	"readOnly":    {},
	"title":       {},
	"writeOnly":   {},
}

// constantMarkedCombinator evaluates a single annotation-only combinator
// whose boolean/empty members make its result constant. JSON Schema gives
// these exact identities: allOf(false, X)=false, allOf(true...)=true,
// anyOf(true, X)=true, anyOf(false...)=false, and oneOf is constant only
// when every member is a known boolean schema.
func constantMarkedCombinator(dict map[string]any) (accepts bool, annotations map[string]any, ok bool) {
	combinator := ""
	for key := range dict {
		if slices.Contains(schemaUnionKeys, key) {
			if combinator != "" {
				return false, nil, false
			}
			combinator = key
			continue
		}
		if _, annotation := schemaAnnotationKeys[key]; !annotation {
			return false, nil, false
		}
	}
	if combinator == "" {
		return false, nil, false
	}
	variants, valid := dict[combinator].([]any)
	if !valid || len(variants) == 0 {
		return false, nil, false
	}
	knownCount := 0
	trueCount := 0
	for _, raw := range variants {
		variant, isObject := raw.(map[string]any)
		if !isObject {
			continue
		}
		value, known := renderMarkerBoolean(variant)
		if !known {
			continue
		}
		knownCount++
		if value {
			trueCount++
		}
	}
	switch combinator {
	case "allOf":
		if knownCount > trueCount {
			accepts, ok = false, true
		} else if knownCount == len(variants) {
			accepts, ok = true, true
		}
	case "anyOf":
		if trueCount > 0 {
			accepts, ok = true, true
		} else if knownCount == len(variants) {
			accepts, ok = false, true
		}
	case "oneOf":
		if knownCount == len(variants) {
			accepts, ok = trueCount == 1, true
		}
	}
	if !ok {
		return false, nil, false
	}
	annotations = make(map[string]any, len(dict)-1)
	for key, value := range dict {
		if _, annotation := schemaAnnotationKeys[key]; annotation {
			annotations[key] = value
		}
	}
	return accepts, annotations, true
}

func renderMarkerBoolean(dict map[string]any) (bool, bool) {
	if dict["type"] != "string" {
		return false, false
	}
	marker, ok := dict[originalBooleanSchemaKey].(bool)
	if !ok {
		return false, false
	}
	for key := range dict {
		if key == "type" || key == originalBooleanSchemaKey {
			continue
		}
		if _, annotation := schemaAnnotationKeys[key]; !annotation {
			return false, false
		}
	}
	return marker, true
}

func nullableCombinatorUnion(dict map[string]any) bool {
	for _, key := range []string{"anyOf", "oneOf"} {
		variants, ok := dict[key].([]any)
		if !ok {
			continue
		}
		hasNull := false
		hasConcrete := false
		for _, rawVariant := range variants {
			variant, ok := rawVariant.(map[string]any)
			if !ok {
				continue
			}
			if nullable, _ := variant["nullable"].(bool); nullable {
				hasNull = true
			}
			switch member := variant["type"].(type) {
			case string:
				if strings.EqualFold(member, "null") {
					hasNull = true
				} else {
					hasConcrete = true
				}
			case []any:
				for _, rawType := range member {
					if member, ok := rawType.(string); ok {
						if strings.EqualFold(member, "null") {
							hasNull = true
						} else {
							hasConcrete = true
						}
					}
				}
			}
		}
		if hasNull && hasConcrete {
			return true
		}
	}
	return false
}
