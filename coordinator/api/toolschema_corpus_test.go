package api

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"
)

// The E1 crash corpus (2026-07-15 platform errors deep dive): valid JSON-Schema
// shapes that the marker-key heuristic (looksLikeSchemaNode) let through
// untyped, crashing the served Gemma template's `{{ value['type'] | upper }}`
// with "Runtime error: upper filter requires string" (23,134 provider 500s per
// day). Positional awareness fixes them: ANY value under properties /
// patternProperties / items / prefixItems / map-valued additionalProperties /
// anyOf / oneOf / allOf IS a schema and is guaranteed a string `type`.

// A property schema that is a bare `{}` — the "anything" schema, valid and
// emitted by real SDKs for untyped params — must gain {"type":"string"}.
func TestNormalizeToolSchemas_Corpus_EmptyPropertySchema(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"x":{}}}}}]}`)

	x := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["x"], "x")
	if got := tsnType(t, x, "x"); got != "string" {
		t.Errorf("x type = %q, want string", got)
	}
}

// Property schemas whose ONLY content is a non-marker annotation/validation
// key (const / default / title / format / pattern / $ref / minimum /
// maxLength) are valid JSON Schema, carried no marker key, and previously
// stayed typeless. Every one must gain a string type with its original key
// preserved.
func TestNormalizeToolSchemas_Corpus_MarkerlessAnnotationOnlyNodes(t *testing.T) {
	cases := map[string]string{
		"const-only":     `{"const":"fixed"}`,
		"default-only":   `{"default":5}`,
		"title-only":     `{"title":"T"}`,
		"format-only":    `{"format":"date-time"}`,
		"pattern-only":   `{"pattern":"^a"}`,
		"ref-only":       `{"$ref":"#/$defs/x"}`,
		"minimum-only":   `{"minimum":1}`,
		"maxLength-only": `{"maxLength":10}`,
	}
	for name, schema := range cases {
		body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
		  "parameters":{"type":"object","properties":{"x":` + schema + `}}}}]}`)
		out := NormalizeToolSchemas(body)
		x := tsnMap(t, tsnProps(t, out)["x"], name)
		if got := tsnType(t, x, name); got != "string" {
			t.Errorf("%s: type = %q, want string", name, got)
		}
		// The original annotation key survives beside the injected type.
		if len(x) != 2 {
			t.Errorf("%s: node = %#v, want original key + injected type only", name, x)
		}
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

// A scalar non-string `type` (e.g. `"type": 123`) collapses to the structural
// inference instead of reaching `| upper` as a number.
func TestNormalizeToolSchemas_Corpus_ScalarNonStringType(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "n":{"type":123},
	    "b":{"type":true},
	    "o":{"type":42,"properties":{"inner":{}}}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	if got := tsnType(t, tsnMap(t, props["n"], "n"), "n"); got != "string" {
		t.Errorf("n type = %q, want string", got)
	}
	if got := tsnType(t, tsnMap(t, props["b"], "b"), "b"); got != "string" {
		t.Errorf("b type = %q, want string", got)
	}
	o := tsnMap(t, props["o"], "o")
	if got := tsnType(t, o, "o"); got != "object" {
		t.Errorf("o type = %q, want object (inferred from properties)", got)
	}
	inner := tsnMap(t, tsnMap(t, o["properties"], "o.properties")["inner"], "inner")
	if got := tsnType(t, inner, "inner"); got != "string" {
		t.Errorf("o.properties.inner type = %q, want string", got)
	}
}

// patternProperties values are schemas and are traversed like properties.
func TestNormalizeToolSchemas_Corpus_PatternProperties(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "env":{"type":"object","patternProperties":{"^ENV_":{},"^NUM_":{"minimum":0},"^ANY_":true}}}}}}]}`)

	env := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["env"], "env")
	pp := tsnMap(t, env["patternProperties"], "env.patternProperties")
	for _, name := range []string{"^ENV_", "^NUM_", "^ANY_"} {
		node := tsnMap(t, pp[name], name)
		if got := tsnType(t, node, name); got != "string" {
			t.Errorf("patternProperties[%q] type = %q, want string", name, got)
		}
	}
	// A typeless node whose only marker is patternProperties infers "object".
	body2 := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"env":{"patternProperties":{"^X_":{"type":"string"}}}}}}}]}`)
	env2 := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body2))["env"], "env2")
	if got := tsnType(t, env2, "env2"); got != "object" {
		t.Errorf("patternProperties-only node type = %q, want object", got)
	}
}

// prefixItems members (2020-12 tuple schemas) are schemas; the node itself
// infers "array" from prefixItems.
func TestNormalizeToolSchemas_Corpus_PrefixItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "pair":{"prefixItems":[{},{"const":1},true]}}}}}]}`)

	pair := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["pair"], "pair")
	if got := tsnType(t, pair, "pair"); got != "array" {
		t.Errorf("pair type = %q, want array (inferred from prefixItems)", got)
	}
	prefix, ok := pair["prefixItems"].([]any)
	if !ok || len(prefix) != 3 {
		t.Fatalf("prefixItems = %v, want 3 members", pair["prefixItems"])
	}
	// `{}` and boolean members default to string; a const member keeps its
	// value's type ("number" for const 1) so validation stays satisfiable.
	for i, want := range []string{"string", "number", "string"} {
		node := tsnMap(t, prefix[i], "prefixItems member")
		if got := tsnType(t, node, "prefixItems member"); got != want {
			t.Errorf("prefixItems[%d] type = %q, want %q", i, got, want)
		}
	}
}

// Tuple-form `items` (draft-04 array form) members are schema-positional.
func TestNormalizeToolSchemas_Corpus_TupleFormItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "tup":{"type":"array","items":[{},false]}}}}}]}`)

	tup := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["tup"], "tup")
	items, ok := tup["items"].([]any)
	if !ok || len(items) != 2 {
		t.Fatalf("items = %v, want 2 members", tup["items"])
	}
	for i, member := range items {
		node := tsnMap(t, member, "items member")
		if got := tsnType(t, node, "items member"); got != "string" {
			t.Errorf("items[%d] type = %q, want string", i, got)
		}
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
	// Marker-less members default to string; the const member keeps its
	// value's type ("number" for const 3) so validation stays satisfiable.
	for name, expectations := range map[string]struct {
		key   string
		types []string
	}{
		"u": {key: "anyOf", types: []string{"string", "number"}},
		"o": {key: "oneOf", types: []string{"string"}},
		"a": {key: "allOf", types: []string{"string"}},
	} {
		node := tsnMap(t, props[name], name)
		members, ok := node[expectations.key].([]any)
		if !ok || len(members) != len(expectations.types) {
			t.Fatalf("%s.%s = %v, want %d members", name, expectations.key, node[expectations.key], len(expectations.types))
		}
		for i, want := range expectations.types {
			m := tsnMap(t, members[i], expectations.key+" member")
			if got := tsnType(t, m, expectations.key+" member"); got != want {
				t.Errorf("%s.%s[%d] type = %q, want %q", name, expectations.key, i, got, want)
			}
		}
	}
}

// A map-valued additionalProperties that is a bare `{}` is schema-positional
// and gains a type (the bool form stays untouched — see
// TestNormalizeToolSchemas_BareAdditionalPropertiesBoolUntouched).
func TestNormalizeToolSchemas_Corpus_EmptyMapAdditionalProperties(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "meta":{"type":"object","additionalProperties":{}}}}}}]}`)

	meta := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["meta"], "meta")
	addl := tsnMap(t, meta["additionalProperties"], "meta.additionalProperties")
	if got := tsnType(t, addl, "additionalProperties"); got != "string" {
		t.Errorf("additionalProperties type = %q, want string", got)
	}
}

// Positional awareness must NOT leak to non-positional maps: a bare `{}`
// parameters ROOT stays `{}` (the template treats empty params as absent), and
// a marker-less junk map at the root is not typed either.
func TestNormalizeToolSchemas_Corpus_RootStaysMarkerGated(t *testing.T) {
	body := []byte(`{"tools":[` +
		`{"type":"function","function":{"name":"noargs","parameters":{}}},` +
		`{"type":"function","function":{"name":"junk","parameters":{"foo":"bar"}}}]}`)

	out := NormalizeToolSchemas(body)
	if !bytes.Equal(out, body) {
		t.Fatalf("marker-less roots must not be repaired (no re-encode):\n in: %s\nout: %s", body, out)
	}
}

// A typeless node with const/enum keeps its original value semantics: the
// injected render type comes from the finite values, not the string default
// (which made every schema-valid non-string emission fail post-generation
// validation), and a null member beside a concrete one is preserved as
// nullable.
func TestNormalizeToolSchemas_Corpus_TypelessFiniteValues(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "count":{"const":1},
	    "level":{"enum":[1,2,null]},
	    "flag":{"const":true},
	    "tag":{"enum":["a","b"]},
	    "none":{"const":null}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	for name, want := range map[string]string{
		"count": "number",
		"level": "number",
		"flag":  "boolean",
		"tag":   "string",
		"none":  "null",
	} {
		node := tsnMap(t, props[name], name)
		if got := tsnType(t, node, name); got != want {
			t.Errorf("%s type = %q, want %q", name, got, want)
		}
	}
	level := tsnMap(t, props["level"], "level")
	if level["nullable"] != true {
		t.Errorf("level nullable = %v, want true", level["nullable"])
	}
	count := tsnMap(t, props["count"], "count")
	if _, hasNullable := count["nullable"]; hasNullable {
		t.Errorf("count gained a spurious nullable: %#v", count)
	}
}

// The corpus normalization is idempotent (second pass returns identical bytes).
func TestNormalizeToolSchemas_Corpus_Idempotent(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "x":{},"b":true,"n":{"type":123},
	    "env":{"type":"object","patternProperties":{"^E_":{}}},
	    "pair":{"prefixItems":[{}]},
	    "u":{"anyOf":[{}]}},
	  "patternProperties":{"^root_":{"default":1}}}}}]}`)

	once := NormalizeToolSchemas(body)
	if bytes.Equal(once, body) {
		t.Fatal("first pass did not normalize")
	}
	twice := NormalizeToolSchemas(once)
	if !bytes.Equal(once, twice) {
		t.Errorf("not idempotent:\n once: %s\ntwice: %s", once, twice)
	}
	// And the repaired document is valid JSON with all corpus nodes typed.
	var decoded map[string]any
	if err := json.Unmarshal(once, &decoded); err != nil {
		t.Fatalf("normalized body is not valid JSON: %v", err)
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

// The served Gemma template's OBJECT branch falls back to iterating a node's
// OWN keys (`filter_keys=true`) when `properties` is missing or not a mapping;
// containers like patternProperties carry no `type`, so `| upper` throws.
// Every object-typed node must therefore end with a mapping `properties`
// (Swift twin parity: ToolSchemaNormalization + gemma4 enforcement inv. 4).
func TestNormalizeToolSchemas_Corpus_ObjectNodesAlwaysCarryProperties(t *testing.T) {
	// Codex P2 shape: explicit object with patternProperties but no properties.
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "env":{"type":"object","patternProperties":{"^ENV_":{"type":"string"}}}}}}}]}`)
	env := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["env"], "env")
	injected, ok := env["properties"].(map[string]any)
	if !ok {
		t.Fatalf("object node with patternProperties must gain a properties map, got %T", env["properties"])
	}
	if len(injected) != 0 {
		t.Errorf("injected properties = %v, want empty", injected)
	}

	// A typeless patternProperties-only node infers "object" and must gain it too.
	body2 := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"env":{"patternProperties":{"^X_":{"type":"string"}}}}}}}]}`)
	env2 := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body2))["env"], "env2")
	if got := tsnType(t, env2, "env2"); got != "object" {
		t.Fatalf("inferred type = %q, want object", got)
	}
	if _, ok := env2["properties"].(map[string]any); !ok {
		t.Fatalf("inferred-object node must gain a properties map, got %T", env2["properties"])
	}

	// Non-mapping properties on an object node is replaced with an empty map
	// (the template's `is mapping` guard would otherwise re-expose the fallback).
	body3 := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"o":{"type":"object","properties":"junk"}}}}}]}`)
	o := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body3))["o"], "o")
	if _, ok := o["properties"].(map[string]any); !ok {
		t.Fatalf("non-mapping properties must become an empty map, got %T", o["properties"])
	}
}
