package toolpolicy

import (
	"encoding/json"
	"errors"
	"fmt"
	"testing"
)

// Auto never compiles a sampler grammar: its tool calls are checked after
// generation by a validator that implements `pattern` natively. Any regex the
// caller writes must therefore forward untouched. Only the grammar-compiled
// modes fail closed on it.
func TestAutoToolChoiceForwardsArbitraryRegexPatterns(t *testing.T) {
	body := func(choice, pattern string) []byte {
		return []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"lookup",
				"parameters":{"type":"object","properties":{
					"code":{"type":"string","pattern":%q}
				}}
			}}],
			"tool_choice":%q
		}`, pattern, choice))
	}
	for _, pattern := range []string{"^city$", "^[a-z]+$", `^[a-f0-9]{8}$`, `\d{3}-\d{4}`} {
		if _, err := validateToolConstraintRequest(body("auto", pattern)); err != nil {
			t.Fatalf("auto rejected regex %q: %v", pattern, err)
		}
	}
	_, err := validateToolConstraintRequest(body("required", "^[a-z]+$"))
	var typed *ValidationError
	if !errors.As(err, &typed) || typed.Kind != UnsupportedSchema {
		t.Fatalf("constrained mode accepted an uncompilable regex: %T %v", err, err)
	}
}

// Every construct here is decidable by the post-generation JSON-Schema
// validator that auto and none actually use, so the pre-flight must forward
// them verbatim instead of guessing at grammar feasibility it never needs.
func TestAutoToolChoiceAcceptsStandardJSONSchemaConstructs(t *testing.T) {
	schemas := map[string]any{
		"multi-type union": map[string]any{
			"type": []any{"string", "integer"},
		},
		"multi-type oneOf": map[string]any{
			"oneOf": []any{
				map[string]any{"type": "string"},
				map[string]any{"type": "integer"},
			},
		},
		"reference": map[string]any{
			"$ref": "#/$defs/Address",
		},
		"dynamic reference": map[string]any{
			"$dynamicRef": "#address",
		},
		"recursive reference": map[string]any{
			"$recursiveRef": "#",
		},
		"conditional": map[string]any{
			"if":   map[string]any{"properties": map[string]any{"kind": map[string]any{"const": "business"}}},
			"then": map[string]any{"required": []any{"tax_id"}},
		},
		"dependent schema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"credit_card":     map[string]any{"type": "string"},
				"billing_address": map[string]any{"type": "string"},
			},
			"dependentSchemas": map[string]any{
				"credit_card": map[string]any{
					"required": []any{"billing_address"},
				},
			},
		},
		"legacy dependencies": map[string]any{
			"type": "object",
			"dependencies": map[string]any{
				"credit_card": []any{"billing_address"},
			},
		},
		"dependent required": map[string]any{
			"type": "object",
			"dependentRequired": map[string]any{
				"credit_card": []any{"billing_address"},
			},
		},
		"property names": map[string]any{
			"type":          "object",
			"propertyNames": map[string]any{"const": "allowed"},
		},
		"unevaluated properties": map[string]any{
			"type":                  "object",
			"unevaluatedProperties": false,
		},
		"unevaluated items": map[string]any{
			"type":             "array",
			"items":            map[string]any{"type": "string"},
			"unevaluatedItems": false,
		},
		"typeless mixed enum": map[string]any{
			"enum": []any{"a", 1},
		},
		"typeless mixed const union": map[string]any{
			"enum": []any{true, "on"},
		},
		"typeless mixed assertion families": map[string]any{
			"minimum":   5,
			"minLength": 2,
		},
		"typeless not": map[string]any{
			"not": map[string]any{"type": "string"},
		},
	}
	for name, propertySchema := range schemas {
		for _, choice := range []string{"auto", "none"} {
			t.Run(name+"/"+choice, func(t *testing.T) {
				body, err := json.Marshal(map[string]any{
					"model":    "m",
					"messages": []any{map[string]any{"role": "user", "content": "x"}},
					"tools": []any{map[string]any{
						"type": "function",
						"function": map[string]any{
							"name": "lookup",
							"parameters": map[string]any{
								"type":       "object",
								"properties": map[string]any{"value": propertySchema},
							},
						},
					}},
					"tool_choice": choice,
				})
				if err != nil {
					t.Fatal(err)
				}
				if _, err := validateToolConstraintRequest(body); err != nil {
					t.Fatalf("standard JSON-Schema construct rejected: %v", err)
				}
			})
		}
	}
}

func TestAutoToolChoiceAcceptsUniformTypelessFiniteSchemas(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"pick",
			"parameters":{"type":"object","properties":{
				"count":{"const":1},
				"level":{"enum":[1,2,null]},
				"tag":{"enum":["a","b"]},
				"score":{"minimum":5,"maximum":10},
				"neg":{"type":"integer","not":{"const":3}}
			}}
		}}],
		"tool_choice":"auto"
	}`)
	if _, err := validateToolConstraintRequest(body); err != nil {
		t.Fatalf("uniform typeless finite schema rejected: %v", err)
	}
}

func TestAutoAndNoneToolChoicePreserveHostedToolCompatibility(t *testing.T) {
	for _, choice := range []string{"auto", "none"} {
		body := []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"search"}],
			"tools":[
				{"type":"web_search"},
				{"type":"custom","custom":{"name":"raw"}},
				{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}
			],
			"tool_choice":%q
		}`, choice))
		if _, err := validateToolConstraintRequest(body); err != nil {
			t.Fatalf("%s rejected hosted-tool compatibility request: %v", choice, err)
		}
	}

	required := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"search"}],
		"tools":[{"type":"web_search"}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(required); err == nil {
		t.Fatal("required mode silently dropped its only hosted tool")
	}
}

// Alternate tool spellings the PROVIDER renders (top-level name, misc
// type + function dict — InboundChatNormalization.isRepresentableTool) must
// get the same pre-dispatch validation function tools get; only genuinely
// unrepresentable entries (no function dict, no name) are forwarded
// untouched for the provider to drop.
func TestAutoToolChoiceValidatesRepresentableAlternateSpellings(t *testing.T) {
	rejected := map[string]string{
		"bad top-level name": `{"name":"bad name","parameters":{"type":"object"}}`,
		"duplicate across spellings": `{"name":"lookup","parameters":{"type":"object"}},
			{"type":"function","function":{"name":"lookup"}}`,
		"forged marker in top-level parameters": `{"name":"probe","parameters":{
			"type":"object","properties":{"v":{"type":"string",
			"x-darkbloom-original-boolean-schema":true}}}}`,
		"forged marker in custom input_schema": `{"type":"custom","name":"probe","input_schema":{
			"type":"object","properties":{"v":{"type":"string",
			"x-darkbloom-original-boolean-schema":true}}}}`,
	}
	for name, entry := range rejected {
		t.Run(name, func(t *testing.T) {
			body := []byte(`{
				"model":"m",
				"messages":[{"role":"user","content":"x"}],
				"tools":[` + entry + `],
				"tool_choice":"auto"
			}`)
			if _, err := validateToolConstraintRequest(body); err == nil {
				t.Fatal("representable alternate spelling bypassed validation")
			}
		})
	}

	accepted := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[
			{"name":"flat_spelling","parameters":{"type":"object",
				"$defs":{"P":{"type":"string"}},"properties":{"p":{"$ref":"#/$defs/P"}}}},
			{"type":"custom","name":"anthropic_spelling","input_schema":{
				"type":"object","properties":{"v":{"anyOf":[{"type":"string"},{"type":"integer"}]}}}}
		],
		"tool_choice":"auto"
	}`)
	if _, err := validateToolConstraintRequest(accepted); err != nil {
		t.Fatalf("valid alternate spellings rejected: %v", err)
	}
}

func TestAutoToolChoiceAcceptsSupportedDecimalMultipleSchemas(t *testing.T) {
	for _, multiple := range []float64{1, 0.1, 2.5, 1e-200, 3e-40} {
		body, err := json.Marshal(map[string]any{
			"model":    "m",
			"messages": []any{map[string]any{"role": "user", "content": "x"}},
			"tools": []any{map[string]any{
				"type": "function",
				"function": map[string]any{
					"name": "lookup",
					"parameters": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"value": map[string]any{
								"type":       "number",
								"multipleOf": multiple,
							},
						},
					},
				},
			}},
			"tool_choice": "auto",
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := validateToolConstraintRequest(body); err != nil {
			t.Fatalf("supported multipleOf %g rejected: %v", multiple, err)
		}
	}
}

// Exact float representability only matters when the value has to survive a
// round trip through the provider's grammar compiler. Auto never builds one,
// so the literal forwards verbatim; only the constrained modes fail closed.
func TestInexactFiniteValuesFailOnlyInConstrainedModes(t *testing.T) {
	body := func(choice string) []byte {
		return []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"calculate",
				"parameters":{"type":"object","properties":{
					"value":{"type":"number","enum":[0.10000000000000001]}
				}}
			}}],
			"tool_choice":%q
		}`, choice))
	}
	if _, err := validateToolConstraintRequest(body("auto")); err != nil {
		t.Fatalf("auto rejected an inexact finite value: %v", err)
	}
	_, err := validateToolConstraintRequest(body("required"))
	var typed *ValidationError
	if !errors.As(err, &typed) ||
		typed.Kind != UnsupportedSchema {
		t.Fatalf("constrained mode accepted an inexact finite value: %T %v", err, err)
	}
}
