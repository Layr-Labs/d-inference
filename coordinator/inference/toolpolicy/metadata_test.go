package toolpolicy

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// The reserved-metadata walk descends schema *keyword* containers. A property
// literally named after a keyword lives under `properties` and is a schema in
// its own right — it must be traversed as one, and its name must never make
// the parent look like it carries that keyword.
func TestReservedMetadataWalkDistinguishesSchemaKeywordsFromPropertyNames(t *testing.T) {
	body := func(inner string) []byte {
		return []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"lookup",
				"parameters":{"type":"object","properties":{
					"pattern":{"type":"string"},
					"if":{"type":"object","properties":{"x":%s}}
				}}
			}}],
			"tool_choice":"auto"
		}`, inner))
	}
	if _, err := validateToolConstraintRequest(body(`{"type":"string"}`)); err != nil {
		t.Fatalf("properties named after schema keywords rejected: %v", err)
	}
	forged := body(`{"type":"string","x-darkbloom-original-boolean-schema":true}`)
	_, err := validateToolConstraintRequest(forged)
	var typed *ValidationError
	if !errors.As(err, &typed) || typed.Kind != InvalidRequest {
		t.Fatalf("forged marker under a keyword-named property escaped: %T %v", err, err)
	}
}

func TestAutoToolChoiceRejectsForgedBooleanSchemaMetadata(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"lookup",
			"parameters":{"type":"object","properties":{
				"value":{
					"type":"string",
					"x-darkbloom-original-boolean-schema":true
				}
			}}
		}}],
		"tool_choice":"auto"
	}`)
	_, err := validateToolConstraintRequest(body)
	var typed *ValidationError
	if !errors.As(err, &typed) || typed.Kind != InvalidRequest {
		t.Fatalf("forged private schema metadata accepted: %T %v", err, err)
	}
}

// A draft-07 tuple `items` array is a container, not a schema node. Charging
// it a level would halve the reachable depth and let a forged marker hide one
// nest deeper than the budget suggests.
func TestReservedMetadataWalkDoesNotChargeDepthForTupleContainers(t *testing.T) {
	nest := func(leaf any, levels int) any {
		item := leaf
		for range levels {
			item = map[string]any{"type": "array", "items": []any{item}}
		}
		return item
	}
	body := func(leaf any) []byte {
		encoded, err := json.Marshal(map[string]any{
			"model":    "m",
			"messages": []any{map[string]any{"role": "user", "content": "x"}},
			"tools": []any{map[string]any{
				"type": "function",
				"function": map[string]any{
					"name": "lookup",
					"parameters": map[string]any{
						"type":       "object",
						"properties": map[string]any{"value": nest(leaf, 17)},
					},
				},
			}},
			"tool_choice": "auto",
		})
		if err != nil {
			t.Fatal(err)
		}
		return encoded
	}
	clean := map[string]any{"type": "string", "pattern": "^city$"}
	if _, err := validateToolConstraintRequest(body(clean)); err != nil {
		t.Fatalf("deep tuple schema rejected: %v", err)
	}
	forged := map[string]any{"type": "string", originalBooleanSchemaKey: true}
	_, err := validateToolConstraintRequest(body(forged))
	var typed *ValidationError
	if !errors.As(err, &typed) || typed.Kind != InvalidRequest {
		t.Fatalf("tuple containers consumed the metadata walk's depth: %T %v", err, err)
	}
}

// A forged reserved marker used to hide below the old depth-32 scan horizon:
// NormalizeBytes walks to maxToolSchemaDepth and
// constantMarkedCombinator folds marker-only combinators toward the root, so
// a marker planted at depth 33-63 escaped the fail-open guard and could then
// surface as shallow, coordinator-vouched metadata the provider trusts. The
// guard now scans the normalizer's full budget and must catch it.
func TestReservedMetadataGuardScansToNormalizerDepth(t *testing.T) {
	var node any = map[string]any{
		"type": "string", originalBooleanSchemaKey: true,
	}
	for range 40 {
		node = map[string]any{"anyOf": []any{node}}
	}
	body, err := json.Marshal(map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": "x"}},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":       "lookup",
				"parameters": node,
			},
		}},
		"tool_choice": "auto",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, verr := validateToolConstraintRequest(body)
	var typed *ValidationError
	if !errors.As(verr, &typed) || typed.Kind != InvalidRequest ||
		!strings.Contains(typed.Message, "reserved internal metadata") {
		t.Fatalf("forged marker below the old scan horizon escaped: %T %v", verr, verr)
	}
}

// The depth bound fails CLOSED: a schema too deep to finish scanning cannot
// be vouched marker-free (the normalizer walks exactly as deep and folds
// marker-only combinators upward from anywhere it reaches), so it is rejected
// rather than forwarded. Clean schemas within the normalizer's budget still
// pass untouched.
func TestReservedMetadataWalkRejectsSchemasDeeperThanNormalizerBudget(t *testing.T) {
	nest := func(levels int) any {
		var node any = map[string]any{"type": "string", "pattern": "^city$"}
		for range levels {
			node = map[string]any{"anyOf": []any{node}}
		}
		return node
	}
	body := func(parameters any) []byte {
		encoded, err := json.Marshal(map[string]any{
			"model":    "m",
			"messages": []any{map[string]any{"role": "user", "content": "x"}},
			"tools": []any{map[string]any{
				"type": "function",
				"function": map[string]any{
					"name":       "lookup",
					"parameters": parameters,
				},
			}},
			"tool_choice": "auto",
		})
		if err != nil {
			t.Fatal(err)
		}
		return encoded
	}
	// Leaf at depth maxToolSchemaDepth — the deepest node the scan still
	// covers. Clean, so forwarded.
	if _, err := validateToolConstraintRequest(body(nest(maxToolSchemaDepth))); err != nil {
		t.Fatalf("clean schema within the scan depth was rejected: %v", err)
	}
	// Past the budget: undecidable, therefore rejected (400), never vouched.
	_, err := validateToolConstraintRequest(body(nest(maxToolSchemaDepth + 6)))
	var typed *ValidationError
	if !errors.As(err, &typed) || typed.Kind != InvalidRequest ||
		!strings.Contains(typed.Message, "reserved-metadata scan depth") {
		t.Fatalf("schema beyond the scan depth was not rejected: %T %v", err, err)
	}
}
