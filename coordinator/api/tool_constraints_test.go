package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestValidateToolConstraintRequestModes(t *testing.T) {
	base := `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}}}]`
	tests := []struct {
		name   string
		suffix string
		want   toolChoiceMode
	}{
		{"auto omitted", `}`, toolChoiceAuto},
		{"auto explicit", `,"tool_choice":"auto"}`, toolChoiceAuto},
		{"none", `,"tool_choice":"none"}`, toolChoiceNone},
		{"required", `,"tool_choice":"required"}`, toolChoiceRequired},
		{"named nested", `,"tool_choice":{"type":"function","function":{"name":"weather"}}}`, toolChoiceNamed},
		{"named responses", `,"tool_choice":{"type":"function","name":"weather"}}`, toolChoiceNamed},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := validateToolConstraintRequest([]byte(base + test.suffix))
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("mode = %q, want %q", got, test.want)
			}
		})
	}
}

func TestInferencePreludeNormalizesSingleStopForSwiftProtocol(t *testing.T) {
	srv, _ := testServer(t)
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions",
		strings.NewReader(
			`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":"END","metadata":{"exact":9007199254740993,"decimal":0.10000000000000001}}`))
	response := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(response, request)
	if !ok {
		t.Fatalf("prelude failed: %s", response.Body.String())
	}
	var forwarded map[string]any
	if err := json.Unmarshal(prelude.rawBody, &forwarded); err != nil {
		t.Fatal(err)
	}
	stops, ok := forwarded["stop"].([]any)
	if !ok || len(stops) != 1 || stops[0] != "END" {
		t.Fatalf("forwarded stop = %#v", forwarded["stop"])
	}
	for _, literal := range []string{"9007199254740993", "0.10000000000000001"} {
		if !bytes.Contains(prelude.rawBody, []byte(literal)) {
			t.Fatalf("forwarded body lost exact numeric literal %s: %s", literal, prelude.rawBody)
		}
	}
}

func TestValidateToolConstraintRequestRejectsProductionFaultClasses(t *testing.T) {
	tests := []struct {
		name   string
		body   string
		status int
	}{
		{
			"invalid function name",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"bad name"}}],"tool_choice":"required"}`,
			http.StatusBadRequest,
		},
		{
			"named undeclared",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","function":{"name":"missing"}}}`,
			http.StatusBadRequest,
		},
		{
			"unsupported union",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"oneOf":[{"type":"string"},{"type":"integer"}]}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"enum type mismatch",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"string","enum":[1]}}}}}],"tool_choice":"required"}`,
			http.StatusBadRequest,
		},
		{
			"number integer beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9007199254740993}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"number Int max cannot trap provider",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9223372036854775807}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"precision sensitive decimal",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":0.10000000000000001}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"positive integer-valued float beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9007199254740994.0}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"negative integer-valued float beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":-9007199254740994.0}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"string parser delimiter",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"string","const":"bad<tool_call|>value"}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"conflicting named choice",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","name":"safe","function":{"name":"other"}}}`,
			http.StatusBadRequest,
		},
		{
			"mismatched constrained parser",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":"required","tool_call_parser":"json"}`,
			http.StatusBadRequest,
		},
		{
			"non-object historical arguments",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":"[1]"}}]}]}`,
			http.StatusBadRequest,
		},
		{
			"object-valued historical arguments",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":{"x":1}}}]}]}`,
			http.StatusBadRequest,
		},
		{
			"orphan tool result",
			`{"model":"m","messages":[{"role":"tool","tool_call_id":"missing","content":"x"}]}`,
			http.StatusBadRequest,
		},
		{
			"unanswered mid-history call",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":"{}"}}]},{"role":"user","content":"next"}]}`,
			http.StatusBadRequest,
		},
		{
			"parallel policy malformed",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tool_choice":"none","parallel_tool_calls":"false"}`,
			http.StatusBadRequest,
		},
		{
			"constrained stop set is bounded",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":"required","stop":["a","b","c","d","e"]}`,
			http.StatusBadRequest,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := validateToolConstraintRequest([]byte(test.body))
			if err == nil {
				t.Fatal("expected rejection")
			}
			typed, ok := err.(*toolConstraintRequestError)
			if !ok {
				t.Fatalf("unexpected error type %T: %v", err, err)
			}
			if typed.status != test.status {
				t.Fatalf("status = %d, want %d (%v)", typed.status, test.status, err)
			}
		})
	}
}

func TestValidateToolConstraintRequestAcceptsNormalizedSubset(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"parallel_tool_calls":false,
		"tools":[{"type":"function","function":{
			"name":"weather",
			"parameters":{
				"properties":{
					"city":{"type":"string","enum":["Paris","Tokyo"]},
					"days":{"type":["integer","null"]},
					"units":{"type":"array","items":{"type":"string"},"maxItems":3}
				},
				"required":["city"],
				"additionalProperties":false
			}
		}}],
		"tool_choice":"required"
	}`)
	if mode, err := validateToolConstraintRequest(body); err != nil || mode != toolChoiceRequired {
		t.Fatalf("valid supported schema rejected: mode=%q err=%v", mode, err)
	}
}

func TestValidateToolHistoryAllowsTrailingAssistantContinuation(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{
			"role":"assistant",
			"content":"",
			"tool_calls":[{
				"id":"c",
				"type":"function",
				"function":{"name":"safe","arguments":"{}"}
			}]
		}]
	}`)
	if _, err := validateToolConstraintRequest(body); err != nil {
		t.Fatalf("trailing assistant continuation rejected: %v", err)
	}
}

func TestNamedToolChoiceValidatesOnlySelectedSchema(t *testing.T) {
	body := func(choice string) []byte {
		return []byte(fmt.Sprintf(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[
			{"type":"function","function":{
				"name":"selected",
				"parameters":{"type":"object","properties":{"value":{"type":"string"}}}
			}},
			{"type":"function","function":{
				"name":"unused",
				"parameters":{"type":"object","properties":{"value":{"pattern":"^x$"}}}
			}}
		],
		"tool_choice":{"type":"function","function":{"name":%q}}
	}`, choice))
	}
	mode, err := validateToolConstraintRequest(body("selected"))
	if err != nil || mode != toolChoiceNamed {
		t.Fatalf("unselected unsupported schema rejected named choice: mode=%q err=%v", mode, err)
	}

	_, err = validateToolConstraintRequest(body("unused"))
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) || typed.status != http.StatusUnprocessableEntity {
		t.Fatalf("selected unsupported schema accepted: %T %v", err, err)
	}
}

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
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) || typed.status != http.StatusUnprocessableEntity {
		t.Fatalf("constrained mode accepted an uncompilable regex: %T %v", err, err)
	}
}

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
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) || typed.status != http.StatusBadRequest {
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
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) || typed.status != http.StatusBadRequest {
		t.Fatalf("forged private schema metadata accepted: %T %v", err, err)
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

func TestConstrainedGrammarCostChargesNullBranchOnlyWhenEnumAdmitsNull(t *testing.T) {
	nullableEnum := func(enum []any) map[string]any {
		return map[string]any{
			"type": []any{"string", "null"},
			"enum": enum,
		}
	}
	plain := constrainedSchemaGrammarCost(map[string]any{
		"type": "string",
		"enum": []any{"ok"},
	})
	withoutNull := constrainedSchemaGrammarCost(nullableEnum([]any{"ok"}))
	if withoutNull != plain {
		t.Fatalf("enum without null charged a null branch: %d != %d", withoutNull, plain)
	}
	withNull := constrainedSchemaGrammarCost(nullableEnum([]any{"ok", nil}))
	if want := plain + constrainedNullableBranchCost; withNull != want {
		t.Fatalf("enum with null lost its null branch: %d != %d", withNull, want)
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
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) || typed.status != http.StatusBadRequest {
		t.Fatalf("tuple containers consumed the metadata walk's depth: %T %v", err, err)
	}
}

// Running out of depth budget is an UNDECIDABLE result, not a violation: the
// walk only ever asserts "a reserved marker was found here". A schema too deep
// to finish walking (or a malformed nest of bare arrays) must still be
// forwarded — this is exactly the class of pre-flight guess that broke #561.
func TestReservedMetadataWalkForwardsSchemasDeeperThanItsBudget(t *testing.T) {
	var items any = map[string]any{"type": "string", "pattern": "^city$"}
	for range 40 {
		items = []any{items}
	}
	body, err := json.Marshal(map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": "x"}},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": "lookup",
				"parameters": map[string]any{
					"type": "array", "items": items,
				},
			},
		}},
		"tool_choice": "auto",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := validateToolConstraintRequest(body); err != nil {
		t.Fatalf("schema beyond the walk's depth bound was rejected: %v", err)
	}
}

func TestValidateToolConstraintRequestRejectsProviderGrammarExplosion(t *testing.T) {
	var value any = map[string]any{"type": "string"}
	for range 4 {
		value = map[string]any{
			"type":     "array",
			"items":    value,
			"maxItems": 16,
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": "x"}},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": "expand",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"value": value,
					},
				},
			},
		}},
		"tool_choice": "required",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, validationErr := validateToolConstraintRequest(body)
	var typed *toolConstraintRequestError
	if !errors.As(validationErr, &typed) {
		t.Fatalf("expected typed complexity rejection, got %T: %v", validationErr, validationErr)
	}
	if typed.status != http.StatusUnprocessableEntity ||
		!strings.Contains(typed.message, "grammar exceeds") {
		t.Fatalf("unexpected complexity rejection: %+v", typed)
	}
}

func TestValidateToolConstraintRequestRejectsNullArrayBounds(t *testing.T) {
	for _, bound := range []string{"minItems", "maxItems"} {
		t.Run(bound, func(t *testing.T) {
			body := []byte(fmt.Sprintf(`{
				"model":"m",
				"messages":[{"role":"user","content":"x"}],
				"tools":[{"type":"function","function":{
					"name":"expand",
					"parameters":{
						"type":"object",
						"properties":{
							"values":{"type":"array","items":{"type":"string"},"%s":null}
						}
					}
				}}],
				"tool_choice":"required"
			}`, bound))
			_, err := validateToolConstraintRequest(body)
			var typed *toolConstraintRequestError
			if !errors.As(err, &typed) || typed.status != http.StatusBadRequest {
				t.Fatalf("null %s accepted: %T %v", bound, err, err)
			}
		})
	}
}

func TestValidateToolConstraintRequestAcceptsIntegralDecimalArrayBounds(t *testing.T) {
	for _, bounds := range []string{
		`"minItems":1.0,"maxItems":2.0`,
		`"minItems":1e0,"maxItems":2e0`,
	} {
		body := []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"expand",
				"parameters":{"type":"object","properties":{
					"values":{"type":"array","items":{"type":"string"},%s}
				}}
			}}],
			"tool_choice":"required"
		}`, bounds))
		if _, err := validateToolConstraintRequest(body); err != nil {
			t.Fatalf("integral decimal bounds %s rejected: %v", bounds, err)
		}
	}

	fractional := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"expand",
			"parameters":{"type":"object","properties":{
				"values":{"type":"array","items":{"type":"string"},"maxItems":1.5}
			}}
		}}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(fractional); err == nil {
		t.Fatal("fractional array bound accepted")
	}
}

func TestValidateToolConstraintRequestAcceptsMathematicalIntegerFiniteValues(t *testing.T) {
	for _, literal := range []string{
		"1.0", "1e0", "-2.0", "-2e0", "9007199254740993.0",
	} {
		body := []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"calculate",
				"parameters":{"type":"object","properties":{
					"value":{"type":"integer","const":%s}
				}}
			}}],
			"tool_choice":"required"
		}`, literal))
		if _, err := validateToolConstraintRequest(body); err != nil {
			t.Fatalf("mathematical integer %s rejected: %v", literal, err)
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
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) ||
		typed.status != http.StatusUnprocessableEntity {
		t.Fatalf("constrained mode accepted an inexact finite value: %T %v", err, err)
	}
}

// The exact-integer parse must stay LINEAR in the literal length: json.Number
// carries raw request bytes unbounded, so a bignum-backed parse would hand an
// attacker free coordinator CPU per oversized literal.
func TestConstrainedExactNonnegativeIntBoundsAdversarialLiterals(t *testing.T) {
	longDigits := strings.Repeat("9", 4_000_000)
	cases := map[string]struct {
		literal string
		want    int
		wantErr bool
	}{
		"plain":                     {literal: "3", want: 3},
		"integral decimal":          {literal: "2.0", want: 2},
		"integral exponent":         {literal: "2e0", want: 2},
		"scaled exponent":           {literal: "1.6e1", want: 16},
		"zero with long fraction":   {literal: "0." + strings.Repeat("0", 100), want: 0},
		"fractional":                {literal: "1.5", wantErr: true},
		"negative":                  {literal: "-1", wantErr: true},
		"huge exponent":             {literal: "1e1000000", wantErr: true},
		"huge negative exponent":    {literal: "1e-1000000", wantErr: true},
		"multi-megabyte digits":     {literal: longDigits, wantErr: true},
		"multi-megabyte fractional": {literal: "1." + longDigits, wantErr: true},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			start := time.Now()
			got, err := constrainedExactNonnegativeInt(tc.literal)
			if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
				t.Fatalf("parse took %v — superlinear parse regression", elapsed)
			}
			if tc.wantErr {
				if err == nil {
					t.Fatalf("literal accepted: %d", got)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("parse = %d, %v; want %d", got, err, tc.want)
			}
		})
	}
}

func TestValidateToolConstraintRequestChargesNullableBranches(t *testing.T) {
	properties := make(map[string]any, 128)
	for index := range 128 {
		properties[fmt.Sprintf("p%d", index)] = map[string]any{
			"type": []any{"string", "null"},
			"enum": []any{nil},
		}
	}
	tools := make([]any, 64)
	for index := range tools {
		tools[index] = map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": fmt.Sprintf("tool%d", index),
				"parameters": map[string]any{
					"type":       "object",
					"properties": properties,
				},
			},
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":       "m",
		"messages":    []any{map[string]any{"role": "user", "content": "x"}},
		"tools":       tools,
		"tool_choice": "required",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, validationErr := validateToolConstraintRequest(body)
	var typed *toolConstraintRequestError
	if !errors.As(validationErr, &typed) ||
		typed.status != http.StatusUnprocessableEntity ||
		!strings.Contains(typed.message, "grammar exceeds") {
		t.Fatalf("nullable grammar undercharged: %T %v", validationErr, validationErr)
	}
}

func TestEndpointLoweringPreservesConstraintAndParallelPolicy(t *testing.T) {
	responses, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointResponses,
		[]byte(`{"model":"m","input":"x","tools":[{"type":"function","name":"weather","parameters":{"type":"object"}}],"tool_choice":{"type":"function","name":"weather"},"parallel_tool_calls":false}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if mode, err := validateToolConstraintRequest(responses); err != nil || mode != toolChoiceNamed {
		t.Fatalf("Responses constraint lost: mode=%q err=%v body=%s", mode, err, responses)
	}

	messages, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointMessages,
		[]byte(`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"name":"weather","input_schema":{"type":"object"}}],"tool_choice":{"type":"any","disable_parallel_tool_use":true}}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if mode, err := validateToolConstraintRequest(messages); err != nil || mode != toolChoiceRequired {
		t.Fatalf("Messages constraint lost: mode=%q err=%v body=%s", mode, err, messages)
	}
	var lowered map[string]any
	if err := jsonUnmarshalUseNumber(messages, &lowered); err != nil {
		t.Fatal(err)
	}
	if parallel, ok := lowered["parallel_tool_calls"].(bool); !ok || parallel {
		t.Fatalf("disable_parallel_tool_use was not preserved: %v", lowered)
	}

	parallelHistory, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointResponses,
		[]byte(`{"model":"m","input":[
			{"type":"function_call","call_id":"a","name":"weather","arguments":"{}"},
			{"type":"function_call","call_id":"b","name":"weather","arguments":"{}"},
			{"type":"function_call_output","call_id":"a","output":"A"},
			{"type":"function_call_output","call_id":"b","output":"B"}
		]}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := validateToolConstraintRequest(parallelHistory); err != nil {
		t.Fatalf("valid parallel Responses history rejected: %v\n%s", err, parallelHistory)
	}
}

func TestNullableUnionSurvivesEveryEndpointNormalization(t *testing.T) {
	schema := `{"type":"object","properties":{"value":{"type":["STRING","NULL"],"nullable":false,"enum":[null]}}}`
	tests := []struct {
		name     string
		endpoint promptcontract.Endpoint
		body     string
		lower    bool
	}{
		{
			name: "chat",
			body: `{"model":"m","messages":[{"role":"user","content":"x"}],` +
				`"tools":[{"type":"function","function":{"name":"f","parameters":` +
				schema + `}}],"tool_choice":"required"}`,
		},
		{
			name: "responses", endpoint: promptcontract.EndpointResponses, lower: true,
			body: `{"model":"m","input":"x","tools":[{"type":"function","name":"f","parameters":` +
				schema + `}],"tool_choice":"required"}`,
		},
		{
			name: "messages", endpoint: promptcontract.EndpointMessages, lower: true,
			body: `{"model":"m","messages":[{"role":"user","content":"x"}],` +
				`"tools":[{"name":"f","input_schema":` + schema +
				`}],"tool_choice":{"type":"any"}}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			body := []byte(test.body)
			if test.lower {
				var err error
				body, err = promptcontract.LowerProviderBody(
					test.endpoint, body)
				if err != nil {
					t.Fatal(err)
				}
			}
			if _, err := validateToolConstraintRequest(body); err != nil {
				t.Fatalf("pre-normalization validation: %v", err)
			}
			normalized := NormalizeToolSchemas(body)
			if _, err := validateToolConstraintRequest(normalized); err != nil {
				t.Fatalf("post-normalization validation: %v\n%s", err, normalized)
			}
			var root map[string]any
			if err := json.Unmarshal(normalized, &root); err != nil {
				t.Fatal(err)
			}
			tools := root["tools"].([]any)
			function := tools[0].(map[string]any)["function"].(map[string]any)
			parameters := function["parameters"].(map[string]any)
			properties := parameters["properties"].(map[string]any)
			value := properties["value"].(map[string]any)
			if value["nullable"] != true {
				t.Fatalf("nullable union was lost: %#v", value)
			}
		})
	}
}

func jsonUnmarshalUseNumber(body []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	return decoder.Decode(output)
}

func TestResponsesEchoEnforcedToolPolicy(t *testing.T) {
	traits := registry.RequestTraits{
		ToolChoiceMode:    string(toolChoiceNamed),
		ToolChoiceName:    "weather",
		ParallelToolCalls: false,
	}
	snapshot := responsesSnapshot(
		"resp", 1, "model", "in_progress", nil, nil, nil, traits)
	if snapshot["parallel_tool_calls"] != false {
		t.Fatalf("stream snapshot lost parallel policy: %#v", snapshot)
	}
	choice, ok := snapshot["tool_choice"].(map[string]any)
	if !ok || choice["type"] != "function" || choice["name"] != "weather" {
		t.Fatalf("stream snapshot lost named choice: %#v", snapshot)
	}
	response := buildResponsesResponse(
		"request", "model", extractedMessage{Content: "ok"},
		protocol.UsageInfo{}, 16, "", "", traits)
	if response.ParallelToolCalls || response.ToolChoice == nil {
		t.Fatalf("nonstreaming response lost tool policy: %+v", response)
	}
}
