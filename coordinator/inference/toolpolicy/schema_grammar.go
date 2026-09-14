package toolpolicy

import (
	"encoding/json"
)

const (
	constrainedMaxArrayItems        = 16
	constrainedMaxGrammarComplexity = 50_000
	constrainedSchemaFixedCost      = 8
	constrainedNullableBranchCost   = 4
)

func constrainedSchemaGrammarCost(raw any) int {
	schema, ok := raw.(map[string]any)
	if !ok {
		return constrainedMaxGrammarComplexity + 1
	}
	kind, nullable, err := constrainedSchemaType(schema)
	if err != nil {
		return constrainedMaxGrammarComplexity + 1
	}
	if rawNullable, exists := schema["nullable"]; exists {
		flag, ok := rawNullable.(bool)
		if !ok {
			return constrainedMaxGrammarComplexity + 1
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
		baseCost = constrainedGrammarAdd(baseCost, constrainedNullableBranchCost)
	}
	payloadCost := 0
	switch kind {
	case "object":
		payloadCost = 2
		properties, _ := schema["properties"].(map[string]any)
		for name, child := range properties {
			payloadCost = constrainedGrammarAdd(
				payloadCost, len([]byte(name))+2+constrainedSchemaGrammarCost(child))
		}
	case "array":
		count := constrainedMaxArrayItems
		if maximum, present, parseErr := constrainedOptionalInt(schema["maxItems"]); parseErr == nil && present {
			count = maximum
		}
		itemCost := constrainedSchemaGrammarCost(schema["items"])
		payloadCost = constrainedGrammarAdd(
			2, constrainedGrammarMultiply(itemCost+1, count))
	case "string":
		if !finite {
			payloadCost = 16
		} else {
			for _, value := range values {
				if text, ok := value.(string); ok {
					payloadCost = constrainedGrammarAdd(
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
					payloadCost = constrainedGrammarAdd(
						payloadCost, len(number.String()))
				}
			}
		}
	case "null":
		payloadCost = 4
	default:
		return constrainedMaxGrammarComplexity + 1
	}
	return constrainedGrammarAdd(baseCost, payloadCost)
}

func constrainedGrammarAdd(lhs, rhs int) int {
	if lhs > constrainedMaxGrammarComplexity ||
		rhs > constrainedMaxGrammarComplexity ||
		lhs > constrainedMaxGrammarComplexity-rhs {
		return constrainedMaxGrammarComplexity + 1
	}
	return lhs + rhs
}

func constrainedGrammarMultiply(lhs, rhs int) int {
	if lhs < 0 || rhs < 0 ||
		(rhs != 0 && lhs > constrainedMaxGrammarComplexity/rhs) {
		return constrainedMaxGrammarComplexity + 1
	}
	product := lhs * rhs
	if product > constrainedMaxGrammarComplexity {
		return constrainedMaxGrammarComplexity + 1
	}
	return product
}
