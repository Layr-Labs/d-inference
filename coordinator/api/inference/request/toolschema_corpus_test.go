package request

import (
	"bytes"
	"reflect"
	"testing"
)

// A property schema that is a bare `{}` — the "anything" schema, valid and
// emitted by real SDKs for untyped params — is semantically the boolean
// `true` schema, so it gets the same render-safe rewrite: a string type for
// the template plus the original-boolean-schema marker so provider-side auto
// validation restores allow-all semantics instead of enforcing the synthetic
// string type.
func TestNormalizeToolSchemas_Corpus_EmptyPropertySchema(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"x":{}}}}}]}`)

	x := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["x"], "x")
	expected := map[string]any{
		"type":                   "string",
		originalBooleanSchemaKey: true,
	}
	if !reflect.DeepEqual(x, expected) {
		t.Errorf("x = %#v, want %#v", x, expected)
	}
}

func TestNormalizeToolSchemas_Corpus_ConstantCombinatorsPreserveBooleanSemantics(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "all":{"allOf":[{}],"description":"anything"},
	    "any":{"anyOf":[{"type":"integer"},true]},
	    "deny":{"allOf":[{"type":"integer"},false]},
	    "one":{"oneOf":[true]}
	  }}}}]}`)
	props := tsnProps(t, NormalizeToolSchemas(body))
	for name, want := range map[string]bool{
		"all": true, "any": true, "deny": false, "one": true,
	} {
		node := tsnMap(t, props[name], name)
		if got, ok := node[originalBooleanSchemaKey].(bool); !ok || got != want {
			t.Errorf("%s marker = %#v, want %v", name, node, want)
		}
		if node["type"] != "string" {
			t.Errorf("%s type = %#v, want render-safe string", name, node["type"])
		}
	}
	all := tsnMap(t, props["all"], "all")
	if all["description"] != "anything" {
		t.Errorf("annotation lost during combinator fold: %#v", all)
	}
}

// A required/named request with an empty `{}` property compiles as a free
// string in grammar modes: the marker rewrite must survive constrained
// re-validation instead of failing on the reserved key.
func TestConstrainedValidationAcceptsNormalizedEmptySchemaMarker(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"lookup",
			"parameters":{"type":"object","properties":{"x":{}}}
		}}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(body); err != nil {
		t.Fatalf("pre-normalization validation: %v", err)
	}
	normalized := NormalizeToolSchemas(body)
	if _, err := validateToolConstraintRequest(normalized); err != nil {
		t.Fatalf("post-normalization validation: %v\n%s", err, normalized)
	}

	// Any marker-bearing shape other than the exact rewrite fails closed.
	forged := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"lookup",
			"parameters":{"type":"object","properties":{"x":{
				"type":"string",
				"x-darkbloom-original-boolean-schema":false
			}}}
		}}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(forged); err == nil {
		t.Fatal("non-canonical marker shape accepted in constrained mode")
	}
}

// Boolean property schemas (`"x": true` / `"y": false`) are valid JSON Schema
// (allow-all / deny-all). The template subscripts every property value, so
// booleans become render-safe string schemas while retaining their original
// semantics for provider-side auto validation.
func TestNormalizeToolSchemas_Corpus_BooleanPropertySchemas(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"x":true,"y":false}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	for name, want := range map[string]bool{"x": true, "y": false} {
		node := tsnMap(t, props[name], name)
		expected := map[string]any{
			"type":                   "string",
			originalBooleanSchemaKey: want,
		}
		if !reflect.DeepEqual(node, expected) {
			t.Errorf("%s = %#v, want %#v", name, node, expected)
		}
	}
}

// A boolean `items` value (valid: `items: true`) is schema-positional too.
func TestNormalizeToolSchemas_Corpus_BooleanItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"arr":{"type":"array","items":true}}}}}]}`)

	arr := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["arr"], "arr")
	items := tsnMap(t, arr["items"], "arr.items")
	expected := map[string]any{
		"type":                   "string",
		originalBooleanSchemaKey: true,
	}
	if !reflect.DeepEqual(items, expected) {
		t.Errorf("items = %#v, want %#v", items, expected)
	}
}

// Union members are schema-positional even when marker-less.
func TestNormalizeToolSchemas_Corpus_MarkerlessUnionMembers(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "u":{"anyOf":[{},{"const":3}]},
	    "o":{"oneOf":[{"format":"uuid"}]},
	    "a":{"allOf":[{}]}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	// anyOf containing allow-all and allOf containing only allow-all are
	// themselves allow-all; preserve that instead of inheriting the marker's
	// render-only string type.
	for _, name := range []string{"u", "a"} {
		node := tsnMap(t, props[name], name)
		if marker, ok := node[originalBooleanSchemaKey].(bool); !ok || !marker {
			t.Errorf("%s = %#v, want allow-all marker", name, node)
		}
	}
	// A non-constant oneOf still retains and normalizes its member.
	o := tsnMap(t, props["o"], "o")
	members, ok := o["oneOf"].([]any)
	if !ok || len(members) != 1 {
		t.Fatalf("o.oneOf = %v, want one member", o["oneOf"])
	}
	member := tsnMap(t, members[0], "oneOf member")
	if got := tsnType(t, member, "oneOf member"); got != "string" {
		t.Errorf("o.oneOf[0] type = %q, want string", got)
	}
}

// Depth ceiling still bounds the positional traversal: a chain nested past
// maxToolSchemaDepth returns the deep tail unrepaired (and unchanged).
func TestNormalizeToolSchemas_Corpus_DepthCeilingStillHolds(t *testing.T) {
	body := tsnDeepPropertiesBody(maxToolSchemaDepth + 4)
	out := NormalizeToolSchemas(body)
	// The document normalizes (outer levels gain types) without hanging or
	// blowing the stack; the leaf past the ceiling is allowed to stay typeless.
	if bytes.Equal(out, body) {
		t.Fatal("outer levels above the ceiling should still normalize")
	}
}
