package request_test

import (
	"bytes"
	"encoding/json"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// The E1 crash corpus (2026-07-15 platform errors deep dive): valid JSON-Schema
// shapes that the marker-key heuristic (looksLikeSchemaNode) let through
// untyped, crashing the served Gemma template's `{{ value['type'] | upper }}`
// with "Runtime error: upper filter requires string" (23,134 provider 500s per
// day). Positional awareness fixes them: ANY value under properties /
// patternProperties / items / prefixItems / map-valued additionalProperties /
// anyOf / oneOf / allOf IS a schema and is guaranteed a string `type`.

// Property schemas whose ONLY content is a non-marker annotation/validation
// key (const / default / title / format / pattern / $ref / maxLength) are
// valid JSON Schema, carried no marker key, and previously stayed typeless.
// Every one must gain a string type with its original key preserved
// (string-family assertions like pattern/maxLength infer "string"; annotations
// like default/title/format fall to the string default).
func TestNormalizeToolSchemas_Corpus_MarkerlessAnnotationOnlyNodes(t *testing.T) {
	cases := map[string]string{
		"const-only":     `{"const":"fixed"}`,
		"default-only":   `{"default":5}`,
		"title-only":     `{"title":"T"}`,
		"format-only":    `{"format":"date-time"}`,
		"pattern-only":   `{"pattern":"^a"}`,
		"ref-only":       `{"$ref":"#/$defs/x"}`,
		"maxLength-only": `{"maxLength":10}`,
	}
	for name, schema := range cases {
		body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
		  "parameters":{"type":"object","properties":{"x":` + schema + `}}}}]}`)
		out := inreq.NormalizeToolSchemas(body)
		x := publicTsnMap(t, publicTsnProps(t, out)["x"], name)
		if got := publicTsnType(t, x, name); got != "string" {
			t.Errorf("%s: type = %q, want string", name, got)
		}
		// The original annotation key survives beside the injected type.
		if len(x) != 2 {
			t.Errorf("%s: node = %#v, want original key + injected type only", name, x)
		}
	}
}

// A typeless node whose only content is type-scoped assertions keeps the
// family those assertions constrain: `{"minimum":5}` accepts 6, so the
// injected render type must be "number" — the string default would make
// every schema-valid emission fail post-generation validation.
func TestNormalizeToolSchemas_Corpus_TypelessAssertionFamilies(t *testing.T) {
	cases := map[string]struct {
		schema string
		want   string
	}{
		"minimum":       {schema: `{"minimum":1}`, want: "number"},
		"multipleOf":    {schema: `{"multipleOf":2}`, want: "number"},
		"minItems":      {schema: `{"minItems":1,"maxItems":4}`, want: "array"},
		"uniqueItems":   {schema: `{"uniqueItems":true}`, want: "array"},
		"required":      {schema: `{"required":["a"]}`, want: "object"},
		"minProperties": {schema: `{"minProperties":1}`, want: "object"},
	}
	for name, tc := range cases {
		body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
		  "parameters":{"type":"object","properties":{"x":` + tc.schema + `}}}}]}`)
		x := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body))["x"], name)
		if got := publicTsnType(t, x, name); got != tc.want {
			t.Errorf("%s: type = %q, want %q", name, got, tc.want)
		}
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

	props := publicTsnProps(t, inreq.NormalizeToolSchemas(body))
	if got := publicTsnType(t, publicTsnMap(t, props["n"], "n"), "n"); got != "string" {
		t.Errorf("n type = %q, want string", got)
	}
	if got := publicTsnType(t, publicTsnMap(t, props["b"], "b"), "b"); got != "string" {
		t.Errorf("b type = %q, want string", got)
	}
	o := publicTsnMap(t, props["o"], "o")
	if got := publicTsnType(t, o, "o"); got != "object" {
		t.Errorf("o type = %q, want object (inferred from properties)", got)
	}
	inner := publicTsnMap(t, publicTsnMap(t, o["properties"], "o.properties")["inner"], "inner")
	if got := publicTsnType(t, inner, "inner"); got != "string" {
		t.Errorf("o.properties.inner type = %q, want string", got)
	}
}

// patternProperties values are schemas and are traversed like properties.
func TestNormalizeToolSchemas_Corpus_PatternProperties(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "env":{"type":"object","patternProperties":{"^ENV_":{},"^NUM_":{"minimum":0},"^ANY_":true}}}}}}]}`)

	env := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body))["env"], "env")
	pp := publicTsnMap(t, env["patternProperties"], "env.patternProperties")
	// `{}` and boolean values default to string; the minimum-bearing value
	// keeps its assertion's number family so validation stays satisfiable.
	for name, want := range map[string]string{
		"^ENV_": "string", "^NUM_": "number", "^ANY_": "string",
	} {
		node := publicTsnMap(t, pp[name], name)
		if got := publicTsnType(t, node, name); got != want {
			t.Errorf("patternProperties[%q] type = %q, want %q", name, got, want)
		}
	}
	// A typeless node whose only marker is patternProperties infers "object".
	body2 := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"env":{"patternProperties":{"^X_":{"type":"string"}}}}}}}]}`)
	env2 := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body2))["env"], "env2")
	if got := publicTsnType(t, env2, "env2"); got != "object" {
		t.Errorf("patternProperties-only node type = %q, want object", got)
	}
}

// prefixItems members (2020-12 tuple schemas) are schemas; the node itself
// infers "array" from prefixItems.
func TestNormalizeToolSchemas_Corpus_PrefixItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "pair":{"prefixItems":[{},{"const":1},true]}}}}}]}`)

	pair := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body))["pair"], "pair")
	if got := publicTsnType(t, pair, "pair"); got != "array" {
		t.Errorf("pair type = %q, want array (inferred from prefixItems)", got)
	}
	prefix, ok := pair["prefixItems"].([]any)
	if !ok || len(prefix) != 3 {
		t.Fatalf("prefixItems = %v, want 3 members", pair["prefixItems"])
	}
	// `{}` and boolean members default to string; a const member keeps its
	// value's type ("number" for const 1) so validation stays satisfiable.
	for i, want := range []string{"string", "number", "string"} {
		node := publicTsnMap(t, prefix[i], "prefixItems member")
		if got := publicTsnType(t, node, "prefixItems member"); got != want {
			t.Errorf("prefixItems[%d] type = %q, want %q", i, got, want)
		}
	}
}

// Tuple-form `items` (draft-04 array form) members are schema-positional.
func TestNormalizeToolSchemas_Corpus_TupleFormItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "tup":{"type":"array","items":[{},false]}}}}}]}`)

	tup := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body))["tup"], "tup")
	items, ok := tup["items"].([]any)
	if !ok || len(items) != 2 {
		t.Fatalf("items = %v, want 2 members", tup["items"])
	}
	for i, member := range items {
		node := publicTsnMap(t, member, "items member")
		if got := publicTsnType(t, node, "items member"); got != "string" {
			t.Errorf("items[%d] type = %q, want string", i, got)
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

	meta := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body))["meta"], "meta")
	addl := publicTsnMap(t, meta["additionalProperties"], "meta.additionalProperties")
	if got := publicTsnType(t, addl, "additionalProperties"); got != "string" {
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

	out := inreq.NormalizeToolSchemas(body)
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

	props := publicTsnProps(t, inreq.NormalizeToolSchemas(body))
	for name, want := range map[string]string{
		"count": "number",
		"level": "number",
		"flag":  "boolean",
		"tag":   "string",
		"none":  "null",
	} {
		node := publicTsnMap(t, props[name], name)
		if got := publicTsnType(t, node, name); got != want {
			t.Errorf("%s type = %q, want %q", name, got, want)
		}
	}
	level := publicTsnMap(t, props["level"], "level")
	if level["nullable"] != true {
		t.Errorf("level nullable = %v, want true", level["nullable"])
	}
	count := publicTsnMap(t, props["count"], "count")
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

	once := inreq.NormalizeToolSchemas(body)
	if bytes.Equal(once, body) {
		t.Fatal("first pass did not normalize")
	}
	twice := inreq.NormalizeToolSchemas(once)
	if !bytes.Equal(once, twice) {
		t.Errorf("not idempotent:\n once: %s\ntwice: %s", once, twice)
	}
	// And the repaired document is valid JSON with all corpus nodes typed.
	var decoded map[string]any
	if err := json.Unmarshal(once, &decoded); err != nil {
		t.Fatalf("normalized body is not valid JSON: %v", err)
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
	env := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body))["env"], "env")
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
	env2 := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body2))["env"], "env2")
	if got := publicTsnType(t, env2, "env2"); got != "object" {
		t.Fatalf("inferred type = %q, want object", got)
	}
	if _, ok := env2["properties"].(map[string]any); !ok {
		t.Fatalf("inferred-object node must gain a properties map, got %T", env2["properties"])
	}

	// Non-mapping properties on an object node is replaced with an empty map
	// (the template's `is mapping` guard would otherwise re-expose the fallback).
	body3 := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"o":{"type":"object","properties":"junk"}}}}}]}`)
	o := publicTsnMap(t, publicTsnProps(t, inreq.NormalizeToolSchemas(body3))["o"], "o")
	if _, ok := o["properties"].(map[string]any); !ok {
		t.Fatalf("non-mapping properties must become an empty map, got %T", o["properties"])
	}
}
