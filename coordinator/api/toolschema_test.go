package api

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// Tests for NormalizeToolSchemas (DAR-130), ported case-for-case from the
// Swift provider's ToolSchemaNormalizationTests
// (provider-swift/Tests/ProviderCoreTests/ToolSchemaNormalizationTests.swift),
// plus Go-specific coverage: number round-tripping (UseNumber), sibling-field
// survival, idempotency, and the byte-gate/JSON-gate split.

// tsnDecode decodes a body with UseNumber (matching the implementation) and
// asserts it is a JSON object.
func tsnDecode(t *testing.T, body []byte) map[string]any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("decoding body: %v\nbody: %s", err, body)
	}
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("body decoded to %T, want JSON object", v)
	}
	return m
}

// tsnMap asserts v is a JSON object.
func tsnMap(t *testing.T, v any, what string) map[string]any {
	t.Helper()
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("%s is %T (%v), want JSON object", what, v, v)
	}
	return m
}

// tsnTools returns the decoded tools array from a body, asserting its length.
func tsnTools(t *testing.T, body []byte, wantLen int) []any {
	t.Helper()
	root := tsnDecode(t, body)
	tools, ok := root["tools"].([]any)
	if !ok || len(tools) != wantLen {
		t.Fatalf("tools = %v (%T), want array of %d", root["tools"], root["tools"], wantLen)
	}
	return tools
}

// tsnFirstToolFn returns tools[0].function from a body.
func tsnFirstToolFn(t *testing.T, body []byte) map[string]any {
	t.Helper()
	root := tsnDecode(t, body)
	tools, ok := root["tools"].([]any)
	if !ok || len(tools) == 0 {
		t.Fatalf("tools is %T (%v), want non-empty array", root["tools"], root["tools"])
	}
	return tsnMap(t, tsnMap(t, tools[0], "tools[0]")["function"], "tools[0].function")
}

// tsnParams returns tools[0].function.parameters.
func tsnParams(t *testing.T, body []byte) map[string]any {
	t.Helper()
	return tsnMap(t, tsnFirstToolFn(t, body)["parameters"], "parameters")
}

// tsnProps returns tools[0].function.parameters.properties.
func tsnProps(t *testing.T, body []byte) map[string]any {
	t.Helper()
	return tsnMap(t, tsnParams(t, body)["properties"], "parameters.properties")
}

// tsnType asserts the node's `type` is a string and returns it.
func tsnType(t *testing.T, node map[string]any, what string) string {
	t.Helper()
	s, ok := node["type"].(string)
	if !ok {
		t.Fatalf("%s type is %T (%v), want string", what, node["type"], node["type"])
	}
	return s
}

// tsnPadBody builds a valid, normalizable tool body of exactly total bytes
// (a typeless enum-only property that WOULD gain a type if parsed).
func tsnPadBody(t *testing.T, total int) []byte {
	t.Helper()
	const prefix = `{"pad":"`
	const suffix = `","tools":[{"type":"function","function":{"name":"f","parameters":{"properties":{"u":{"enum":["c","f"]}}}}}]}`
	pad := total - len(prefix) - len(suffix)
	if pad < 0 {
		t.Fatalf("total %d smaller than the fixed body parts", total)
	}
	body := prefix + strings.Repeat("a", pad) + suffix
	if len(body) != total {
		t.Fatalf("built %d bytes, want %d", len(body), total)
	}
	return []byte(body)
}

// Swift: injectsTypeIntoTypelessParameterPropertyAndObject
func TestNormalizeToolSchemas_InjectsTypeIntoTypelessParameterPropertyAndObject(t *testing.T) {
	// A legitimate OpenAI schema: the `unit` property has enum+description but
	// no explicit `type`, and the parameters object itself omits `type`.
	body := []byte(`{"model":"gemma-4-26b","messages":[{"role":"user","content":"hi"}],
	 "tools":[{"type":"function","function":{"name":"get_weather",
	   "parameters":{"properties":{"unit":{"enum":["c","f"],"description":"unit"}}}}}]}`)

	out := NormalizeToolSchemas(body)
	params := tsnParams(t, out)
	if got := tsnType(t, params, "parameters"); got != "object" {
		t.Errorf("parameters type = %q, want object", got)
	}
	unit := tsnMap(t, tsnMap(t, params["properties"], "properties")["unit"], "unit")
	// Defaulted to "string" so `{{ value['type'] | upper }}` no longer throws.
	if got := tsnType(t, unit, "unit"); got != "string" {
		t.Errorf("unit type = %q, want string", got)
	}
	// The original enum/description are preserved.
	if enum, ok := unit["enum"].([]any); !ok || len(enum) != 2 {
		t.Errorf("unit enum = %v, want 2 members", unit["enum"])
	}
	if unit["description"] != "unit" {
		t.Errorf("unit description = %v, want %q", unit["description"], "unit")
	}
}

// Swift: preservesExistingTypesAndNestedArrays
func TestNormalizeToolSchemas_PreservesExistingTypesAndNestedArrays(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "tags":{"type":"array","items":{"description":"a tag"}},
	    "q":{"type":"string"}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	// Existing types untouched.
	if got := tsnType(t, tsnMap(t, props["q"], "q"), "q"); got != "string" {
		t.Errorf("q type = %q, want string", got)
	}
	tags := tsnMap(t, props["tags"], "tags")
	if got := tsnType(t, tags, "tags"); got != "array" {
		t.Errorf("tags type = %q, want array", got)
	}
	// Nested array `items` schema with no type gets defaulted.
	items := tsnMap(t, tags["items"], "tags.items")
	if got := tsnType(t, items, "tags.items"); got != "string" {
		t.Errorf("items type = %q, want string", got)
	}
	if items["description"] != "a tag" {
		t.Errorf("items description = %v, want %q", items["description"], "a tag")
	}
}

// Swift: nonToolBodyReturnedUnchanged
func TestNormalizeToolSchemas_NonToolBodyReturnedUnchanged(t *testing.T) {
	noTools := []byte(`{"model":"m","messages":[]}`)
	if out := NormalizeToolSchemas(noTools); !bytes.Equal(out, noTools) {
		t.Errorf("no-tools body changed: %s", out)
	}
}

// Swift: recursesIntoAdditionalProperties
func TestNormalizeToolSchemas_RecursesIntoAdditionalProperties(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "meta":{"additionalProperties":{"description":"a value"}}}}}}]}`)

	meta := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["meta"], "meta")
	// The map-shaped param node is typed "object"...
	if got := tsnType(t, meta, "meta"); got != "object" {
		t.Errorf("meta type = %q, want object", got)
	}
	// ...and its inner additionalProperties schema gets a default type too.
	addl := tsnMap(t, meta["additionalProperties"], "meta.additionalProperties")
	if got := tsnType(t, addl, "additionalProperties"); got != "string" {
		t.Errorf("additionalProperties type = %q, want string", got)
	}
	if addl["description"] != "a value" {
		t.Errorf("additionalProperties description = %v, want %q", addl["description"], "a value")
	}
}

// Swift: derivesUnionTypeInsteadOfBlanketString
func TestNormalizeToolSchemas_DerivesUnionTypeInsteadOfBlanketString(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "n":{"anyOf":[{"type":"number"},{"type":"null"}]}}}}}]}`)

	n := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["n"], "n")
	// A nullable-number union borrows "number", not a mislabelling "string".
	if got := tsnType(t, n, "n"); got != "number" {
		t.Errorf("n type = %q, want number", got)
	}
	if variants, ok := n["anyOf"].([]any); !ok || len(variants) != 2 {
		t.Errorf("anyOf = %v, want 2 members preserved", n["anyOf"])
	}
}

// Swift: skipsNormalizationForOversizedBodies (+ at-cap boundary processed)
func TestNormalizeToolSchemas_SkipsNormalizationForOversizedBodies(t *testing.T) {
	// A body above the cap is returned unchanged BEFORE any parse, even though
	// it contains "tools" and a schema that WOULD be repaired — bounding the
	// JSON round-trip cost (DoS amplification).
	over := tsnPadBody(t, maxToolNormalizationBytes+1)
	if out := NormalizeToolSchemas(over); !bytes.Equal(out, over) {
		t.Error("oversized body was modified")
	}
	// At exactly the cap the body is still normalized (the gate is strictly >).
	at := tsnPadBody(t, maxToolNormalizationBytes)
	out := NormalizeToolSchemas(at)
	if bytes.Equal(out, at) {
		t.Fatal("at-cap body was not normalized")
	}
	u := tsnMap(t, tsnProps(t, out)["u"], "u")
	if got := tsnType(t, u, "u"); got != "string" {
		t.Errorf("u type = %q, want string", got)
	}
}

// Array-typed (nullable) `type` values — the second DAR-130 class.
// `"type": ["string","null"]` is what Pydantic emits for Optional[...] tool
// parameters; the gemma template's `| upper` crashed on the list ("upper
// filter requires string", reproduced on prod 2026-06-10).

// Swift: collapsesNullableArrayTypeToConcreteMember
func TestNormalizeToolSchemas_CollapsesNullableArrayTypeToConcreteMember(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"get_weather",
	  "parameters":{"type":"object","properties":{
	    "city":{"type":["string","null"],"description":"city"}},
	    "required":["city"]}}}]}`)

	out := NormalizeToolSchemas(body)
	city := tsnMap(t, tsnProps(t, out)["city"], "city")
	if got := tsnType(t, city, "city"); got != "string" {
		t.Errorf("city type = %q, want string", got)
	}
	// Nullability preserved losslessly via the template-supported key.
	if city["nullable"] != true {
		t.Errorf("city nullable = %v, want true", city["nullable"])
	}
	if req, ok := tsnParams(t, out)["required"].([]any); !ok || len(req) != 1 || req[0] != "city" {
		t.Errorf("required = %v, want [city]", tsnParams(t, out)["required"])
	}
}

// Swift: collapsesArrayTypeSkippingLeadingNull
func TestNormalizeToolSchemas_CollapsesArrayTypeSkippingLeadingNull(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "n":{"type":["null","integer"]}}}}}]}`)

	n := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["n"], "n")
	if got := tsnType(t, n, "n"); got != "integer" {
		t.Errorf("n type = %q, want integer", got)
	}
	if n["nullable"] != true {
		t.Errorf("n nullable = %v, want true", n["nullable"])
	}
}

// Swift: collapsesNullOnlyArrayTypeToNullString
func TestNormalizeToolSchemas_CollapsesNullOnlyArrayTypeToNullString(t *testing.T) {
	// ["null"] has no concrete member — keep the honest "null", which still
	// renders (it is a string for `| upper`).
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "x":{"type":["null"]}}}}}]}`)

	x := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["x"], "x")
	if got := tsnType(t, x, "x"); got != "null" {
		t.Errorf("x type = %q, want null", got)
	}
	// No concrete member was collapsed away, so nullable is NOT synthesized.
	if _, ok := x["nullable"]; ok {
		t.Errorf("x nullable = %v, want absent", x["nullable"])
	}
}

// Swift: collapsesArrayTypeInNestedObjectAndItems
func TestNormalizeToolSchemas_CollapsesArrayTypeInNestedObjectAndItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"set_alarm",
	  "parameters":{"type":"object","properties":{
	    "opts":{"type":"object","properties":{"snooze":{"type":["integer","null"]}}},
	    "tags":{"type":"array","items":{"type":["string","null"]}}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	snooze := tsnMap(t, tsnMap(t, tsnMap(t, props["opts"], "opts")["properties"], "opts.properties")["snooze"], "snooze")
	if got := tsnType(t, snooze, "snooze"); got != "integer" {
		t.Errorf("snooze type = %q, want integer", got)
	}
	if snooze["nullable"] != true {
		t.Errorf("snooze nullable = %v, want true", snooze["nullable"])
	}
	items := tsnMap(t, tsnMap(t, props["tags"], "tags")["items"], "tags.items")
	if got := tsnType(t, items, "tags.items"); got != "string" {
		t.Errorf("items type = %q, want string", got)
	}
	if items["nullable"] != true {
		t.Errorf("items nullable = %v, want true", items["nullable"])
	}
}

// Swift: malformedNonStringTypeFallsBackToStructuralInference
func TestNormalizeToolSchemas_MalformedNonStringTypeFallsBackToStructuralInference(t *testing.T) {
	// A numeric `type` is invalid JSON Schema; repair it from structure
	// (properties present → object) instead of leaving the list/number for
	// the template to choke on.
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "cfg":{"type":42,"properties":{"k":{"type":"string"}}},
	    "v":{"type":7,"description":"v"}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	cfg := tsnMap(t, props["cfg"], "cfg")
	if got := tsnType(t, cfg, "cfg"); got != "object" {
		t.Errorf("cfg type = %q, want object", got)
	}
	v := tsnMap(t, props["v"], "v")
	if got := tsnType(t, v, "v"); got != "string" {
		t.Errorf("v type = %q, want string", got)
	}
	// No "null" member was collapsed, so nullable is not synthesized.
	for name, node := range map[string]map[string]any{"cfg": cfg, "v": v} {
		if _, ok := node["nullable"]; ok {
			t.Errorf("%s nullable = %v, want absent", name, node["nullable"])
		}
	}
}

// Swift: unionMemberWithArrayTypeStillDrivesParentInference
func TestNormalizeToolSchemas_UnionMemberWithArrayTypeStillDrivesParentInference(t *testing.T) {
	// Ordering is load-bearing: members collapse BEFORE the parent's union
	// inference, so a first member declaring ["string","null"] must yield a
	// "string" parent type (not fall through to the default).
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "u":{"anyOf":[{"type":["string","null"]},{"type":"integer"}],"description":"u"}}}}}]}`)

	u := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["u"], "u")
	if got := tsnType(t, u, "u"); got != "string" {
		t.Errorf("u type = %q, want string", got)
	}
	variants, ok := u["anyOf"].([]any)
	if !ok || len(variants) != 2 {
		t.Fatalf("anyOf = %v, want 2 members", u["anyOf"])
	}
	first := tsnMap(t, variants[0], "anyOf[0]")
	if got := tsnType(t, first, "anyOf[0]"); got != "string" {
		t.Errorf("anyOf[0] type = %q, want string (collapsed before parent inference)", got)
	}
	if first["nullable"] != true {
		t.Errorf("anyOf[0] nullable = %v, want true", first["nullable"])
	}
}

// Swift: collapsesArrayTypeOnTopLevelParametersNode
func TestNormalizeToolSchemas_CollapsesArrayTypeOnTopLevelParametersNode(t *testing.T) {
	// The template also renders params['type'] | upper at the top level.
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":["object","null"],"properties":{"q":{"type":"string"}}}}}]}`)

	params := tsnParams(t, NormalizeToolSchemas(body))
	if got := tsnType(t, params, "parameters"); got != "object" {
		t.Errorf("parameters type = %q, want object", got)
	}
	if params["nullable"] != true {
		t.Errorf("parameters nullable = %v, want true", params["nullable"])
	}
}

// Swift: collapsesArrayTypeInsideAdditionalPropertiesSchema
func TestNormalizeToolSchemas_CollapsesArrayTypeInsideAdditionalPropertiesSchema(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "kv":{"type":"object","additionalProperties":{"type":["number","null"]}}}}}}]}`)

	kv := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["kv"], "kv")
	addl := tsnMap(t, kv["additionalProperties"], "kv.additionalProperties")
	if got := tsnType(t, addl, "additionalProperties"); got != "number" {
		t.Errorf("additionalProperties type = %q, want number", got)
	}
	if addl["nullable"] != true {
		t.Errorf("additionalProperties nullable = %v, want true", addl["nullable"])
	}
}

// Go-specific: an explicit `nullable` survives the array-type collapse.
func TestNormalizeToolSchemas_ExplicitNullableLeftUntouched(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "kept":{"type":["string","null"],"nullable":false},
	    "set":{"type":["string","null"]}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	kept := tsnMap(t, props["kept"], "kept")
	if got := tsnType(t, kept, "kept"); got != "string" {
		t.Errorf("kept type = %q, want string", got)
	}
	// The explicit value is NOT clobbered, even though it disagrees.
	if kept["nullable"] != false {
		t.Errorf("kept nullable = %v, want explicit false preserved", kept["nullable"])
	}
	set := tsnMap(t, props["set"], "set")
	if set["nullable"] != true {
		t.Errorf("set nullable = %v, want synthesized true", set["nullable"])
	}
}

// Go-specific: a property whose only marker is `enum` gains "string".
func TestNormalizeToolSchemas_EnumOnlyPropertyGainsStringType(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"e":{"enum":["a","b"]}}}}}]}`)

	e := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["e"], "e")
	if got := tsnType(t, e, "e"); got != "string" {
		t.Errorf("e type = %q, want string", got)
	}
	if enum, ok := e["enum"].([]any); !ok || len(enum) != 2 {
		t.Errorf("e enum = %v, want 2 members preserved", e["enum"])
	}
}

// Go-specific: bare boolean additionalProperties is left untouched (only a
// map-shaped value is recursed), but its presence still drives "object"
// inference on a typeless parent.
func TestNormalizeToolSchemas_BareAdditionalPropertiesBoolUntouched(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "open":{"type":"object","additionalProperties":true},
	    "closed":{"additionalProperties":false}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	open := tsnMap(t, props["open"], "open")
	if open["additionalProperties"] != true {
		t.Errorf("open additionalProperties = %v (%T), want bare true", open["additionalProperties"], open["additionalProperties"])
	}
	closed := tsnMap(t, props["closed"], "closed")
	if got := tsnType(t, closed, "closed"); got != "object" {
		t.Errorf("closed type = %q, want object (inferred from additionalProperties)", got)
	}
	if closed["additionalProperties"] != false {
		t.Errorf("closed additionalProperties = %v (%T), want bare false", closed["additionalProperties"], closed["additionalProperties"])
	}
}

// Go-specific: recursion reaches items.items.properties three levels down.
func TestNormalizeToolSchemas_DeeplyNestedItemsProperties(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "grid":{"type":"array","items":{"items":{"properties":{"name":{"description":"n"}}}}}}}}}]}`)

	grid := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["grid"], "grid")
	l1 := tsnMap(t, grid["items"], "grid.items")
	if got := tsnType(t, l1, "grid.items"); got != "array" {
		t.Errorf("grid.items type = %q, want array (inferred from items)", got)
	}
	l2 := tsnMap(t, l1["items"], "grid.items.items")
	if got := tsnType(t, l2, "grid.items.items"); got != "object" {
		t.Errorf("grid.items.items type = %q, want object (inferred from properties)", got)
	}
	name := tsnMap(t, tsnMap(t, l2["properties"], "innermost properties")["name"], "name")
	if got := tsnType(t, name, "name"); got != "string" {
		t.Errorf("name type = %q, want string", got)
	}
}

// Go-specific: bodies that pass the cheap `"tools"` byte gate but carry no
// top-level tools array must no-op byte-identically.
func TestNormalizeToolSchemas_ToolsBytesWithoutToolsArrayNoOp(t *testing.T) {
	bodies := map[string][]byte{
		// The literal string value "tools" inside a message — the quoted bytes
		// match the gate even though there is no tools key at the top level.
		"tools as prompt string": []byte(`{"model":"m","messages":[{"role":"user","content":"tools"}]}`),
		// A nested "tools" key is NOT the top-level tools array; the embedded
		// typeless schema must stay untouched.
		"nested tools key": []byte(`{"metadata":{"tools":[{"function":{"parameters":{"properties":{"u":{"enum":["c"]}}}}}]},"model":"m"}`),
		// Top-level "tools" present but not an array.
		"tools is a string":  []byte(`{"tools":"none"}`),
		"tools is an object": []byte(`{"tools":{"a":1}}`),
		"tools is null":      []byte(`{"tools":null}`),
	}
	for name, body := range bodies {
		if !bytes.Contains(body, []byte(`"tools"`)) {
			t.Fatalf("%s: test body must pass the byte gate to exercise the JSON gate", name)
		}
		if out := NormalizeToolSchemas(body); !bytes.Equal(out, body) {
			t.Errorf("%s: body changed:\n in: %s\nout: %s", name, body, out)
		}
	}
}

// Go-specific: non-object roots and malformed JSON are returned unchanged.
func TestNormalizeToolSchemas_NonObjectOrMalformedBodyUnchanged(t *testing.T) {
	bodies := map[string][]byte{
		"array root":       []byte(`["tools"]`),
		"string root":      []byte(`"tools"`),
		"truncated JSON":   []byte(`{"tools":[`),
		"trailing garbage": []byte(`{"tools":[]}{"x":1}`),
		"trailing text":    []byte(`{"tools":[]}garbage`),
		"empty body":       {},
	}
	for name, body := range bodies {
		if out := NormalizeToolSchemas(body); !bytes.Equal(out, body) {
			t.Errorf("%s: body changed:\n in: %s\nout: %s", name, body, out)
		}
	}
}

// Go-specific: UseNumber round-trip — int64-range-exceeding integers and
// high-precision decimals survive exactly, and every top-level field other
// than tools survives value-equivalent.
func TestNormalizeToolSchemas_NumbersAndSiblingsSurviveExactly(t *testing.T) {
	// 9007199254740993 = 2^53+1: unrepresentable in float64 (would mangle to
	// ...992 without UseNumber).
	body := []byte(`{"model":"gemma-4-26b","max_tokens":9007199254740993,` +
		`"temperature":0.30000000000000004,"top_p":1e-7,"stream":true,"stop":null,` +
		`"metadata":{"trace":"a<>&b","big":123456789012345678901234567890.5},` +
		`"messages":[{"role":"user","content":"hi"}],` +
		`"tools":[{"type":"function","function":{"name":"f","parameters":` +
		`{"type":"object","properties":{"limit":{"description":"l","default":9007199254740993}}}}}]}`)

	out := NormalizeToolSchemas(body)
	if bytes.Equal(out, body) {
		t.Fatal("body was not normalized (limit should gain a type)")
	}
	// The exact integer literal survives in both positions.
	if got := bytes.Count(out, []byte("9007199254740993")); got != 2 {
		t.Errorf("exact literal 9007199254740993 appears %d times, want 2\nout: %s", got, out)
	}

	root := tsnDecode(t, out)
	for field, want := range map[string]json.Number{
		"max_tokens":  "9007199254740993",
		"temperature": "0.30000000000000004",
		"top_p":       "1e-7",
	} {
		if got := root[field]; got != want {
			t.Errorf("%s = %v (%T), want json.Number %s", field, got, got, want)
		}
	}
	if got := tsnMap(t, root["metadata"], "metadata")["big"]; got != json.Number("123456789012345678901234567890.5") {
		t.Errorf("metadata.big = %v (%T), want exact decimal", got, got)
	}
	limit := tsnMap(t, tsnProps(t, out)["limit"], "limit")
	if got := tsnType(t, limit, "limit"); got != "string" {
		t.Errorf("limit type = %q, want string", got)
	}
	if limit["default"] != json.Number("9007199254740993") {
		t.Errorf("limit default = %v (%T), want exact json.Number", limit["default"], limit["default"])
	}

	// Every sibling of "tools" survives value-equivalent.
	in, outRoot := tsnDecode(t, body), tsnDecode(t, out)
	delete(in, "tools")
	delete(outRoot, "tools")
	if !reflect.DeepEqual(in, outRoot) {
		t.Errorf("non-tools fields diverged:\n in: %#v\nout: %#v", in, outRoot)
	}
}

// Go-specific: normalizing twice equals normalizing once, byte for byte.
func TestNormalizeToolSchemas_Idempotent(t *testing.T) {
	body := []byte(`{"model":"m","max_tokens":9007199254740993,` +
		`"tools":[{"type":"function","function":{"name":"f","parameters":` +
		`{"type":["object","null"],"properties":{` +
		`"u":{"type":["string","null"],"description":"u"},` +
		`"e":{"enum":["a"]},` +
		`"n":{"anyOf":[{"type":["integer","null"]},{"type":"null"}]}}}}}]}`)

	once := NormalizeToolSchemas(body)
	if bytes.Equal(once, body) {
		t.Fatal("first pass did not normalize")
	}
	twice := NormalizeToolSchemas(once)
	if !bytes.Equal(once, twice) {
		t.Errorf("not idempotent:\n once: %s\ntwice: %s", once, twice)
	}
}

// Go-specific: the exact shape from the 2026-06-10 prod incident.
func TestNormalizeToolSchemas_RealWorldIncidentShape(t *testing.T) {
	body := []byte(`{"model":"gemma-4-26b","messages":[{"role":"user","content":"weather in SF"}],` +
		`"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather",` +
		`"parameters":{"type":"object","properties":{` +
		`"location":{"type":"string","description":"city"},` +
		`"unit":{"type":["string","null"],"description":"optional unit"}},` +
		`"required":["location"]}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	unit := tsnMap(t, props["unit"], "unit")
	if got := tsnType(t, unit, "unit"); got != "string" {
		t.Errorf("unit type = %q, want string", got)
	}
	if unit["nullable"] != true {
		t.Errorf("unit nullable = %v, want true", unit["nullable"])
	}
	if unit["description"] != "optional unit" {
		t.Errorf("unit description = %v, want %q", unit["description"], "optional unit")
	}
	location := tsnMap(t, props["location"], "location")
	if got := tsnType(t, location, "location"); got != "string" {
		t.Errorf("location type = %q, want string", got)
	}
	if _, ok := location["nullable"]; ok {
		t.Errorf("location nullable = %v, want absent", location["nullable"])
	}
}

// Go-specific: tool entries that don't match the expected shape pass through
// value-equivalent; well-formed siblings are still normalized.
func TestNormalizeToolSchemas_MalformedToolEntriesPassedThrough(t *testing.T) {
	body := []byte(`{"model":"m","tools":[` +
		`42,` +
		`"x",` +
		`{"type":"function"},` +
		`{"function":"notdict"},` +
		`{"function":{"name":"f"}},` +
		`{"function":{"name":"g","parameters":null}},` +
		`{"function":{"name":"h","parameters":{"properties":{"q":{"description":"q"}}}}}]}`)

	out := NormalizeToolSchemas(body)
	tools, ok := tsnDecode(t, out)["tools"].([]any)
	if !ok || len(tools) != 7 {
		t.Fatalf("tools = %v, want 7 entries", tools)
	}
	if tools[0] != json.Number("42") || tools[1] != "x" {
		t.Errorf("scalar entries changed: %v, %v", tools[0], tools[1])
	}
	if !reflect.DeepEqual(tools[2], map[string]any{"type": "function"}) {
		t.Errorf("function-less entry changed: %#v", tools[2])
	}
	if got := tsnMap(t, tools[3], "tools[3]")["function"]; got != "notdict" {
		t.Errorf("non-object function changed: %v", got)
	}
	fn4 := tsnMap(t, tsnMap(t, tools[4], "tools[4]")["function"], "tools[4].function")
	if _, ok := fn4["parameters"]; ok {
		t.Errorf("parameters key invented on tools[4]: %v", fn4["parameters"])
	}
	fn5 := tsnMap(t, tsnMap(t, tools[5], "tools[5]")["function"], "tools[5].function")
	if v, ok := fn5["parameters"]; !ok || v != nil {
		t.Errorf("null parameters = %v (present=%v), want preserved null", v, ok)
	}
	params6 := tsnMap(t, tsnMap(t, tsnMap(t, tools[6], "tools[6]")["function"], "tools[6].function")["parameters"], "tools[6].parameters")
	if got := tsnType(t, params6, "tools[6].parameters"); got != "object" {
		t.Errorf("valid sibling parameters type = %q, want object", got)
	}
	q := tsnMap(t, tsnMap(t, params6["properties"], "tools[6].properties")["q"], "q")
	if got := tsnType(t, q, "q"); got != "string" {
		t.Errorf("valid sibling q type = %q, want string", got)
	}
}

// Responses-API flat and Anthropic Messages shapes (the DAR-130 breadth
// extension): the coordinator repairs three wire shapes per tool entry; the
// Swift provider-side normalizer covers only the chat shape as of 0.6.4, so
// these paths have no provider-side fallback.

// Responses-API flat tool: parameters at the tool's top level, no "function"
// wrapper. Responses→chat conversion runs AFTER normalization and copies
// parameters verbatim, so the flat repair fixes that path end-to-end. A
// chat-shape sibling in the same array is normalized by its own rule.
func TestNormalizeToolSchemas_ResponsesFlatToolNormalized(t *testing.T) {
	body := []byte(`{"model":"gemma-4-26b","input":"weather in SF","tools":[` +
		`{"type":"function","name":"get_weather","description":"Get weather",` +
		`"parameters":{"type":"object","properties":{` +
		`"city":{"type":["string","null"],"description":"city"},` +
		`"unit":{"enum":["c","f"]}},"required":["city"]}},` +
		`{"type":"function","function":{"name":"chat_sibling",` +
		`"parameters":{"properties":{"q":{"type":["string","null"]}}}}}]}`)

	tools := tsnTools(t, NormalizeToolSchemas(body), 2)

	flat := tsnMap(t, tools[0], "tools[0]")
	// The flat entry's own identity fields survive, and no wrapper is invented.
	if flat["type"] != "function" || flat["name"] != "get_weather" || flat["description"] != "Get weather" {
		t.Errorf("flat tool identity changed: type=%v name=%v description=%v",
			flat["type"], flat["name"], flat["description"])
	}
	if _, ok := flat["function"]; ok {
		t.Errorf("function wrapper invented on flat tool: %v", flat["function"])
	}
	params := tsnMap(t, flat["parameters"], "flat parameters")
	props := tsnMap(t, params["properties"], "flat properties")
	// Nullable array type collapses with nullability preserved.
	city := tsnMap(t, props["city"], "city")
	if got := tsnType(t, city, "city"); got != "string" {
		t.Errorf("city type = %q, want string", got)
	}
	if city["nullable"] != true {
		t.Errorf("city nullable = %v, want true", city["nullable"])
	}
	// Typeless enum-only property gains a type.
	unit := tsnMap(t, props["unit"], "unit")
	if got := tsnType(t, unit, "unit"); got != "string" {
		t.Errorf("unit type = %q, want string", got)
	}
	if req, ok := params["required"].([]any); !ok || len(req) != 1 || req[0] != "city" {
		t.Errorf("required = %v, want [city]", params["required"])
	}

	// The chat-shape sibling is still normalized through the function wrapper.
	sibFn := tsnMap(t, tsnMap(t, tools[1], "tools[1]")["function"], "tools[1].function")
	sibQ := tsnMap(t, tsnMap(t, tsnMap(t, sibFn["parameters"], "sibling parameters")["properties"], "sibling properties")["q"], "q")
	if got := tsnType(t, sibQ, "sibling q"); got != "string" {
		t.Errorf("sibling q type = %q, want string", got)
	}
	if sibQ["nullable"] != true {
		t.Errorf("sibling q nullable = %v, want true", sibQ["nullable"])
	}
}

// Pins the flat-detection rule for a degenerate hybrid: when "function" is
// present but NOT an object, it is opaque garbage rather than a chat wrapper
// — the entry counts as flat, its top-level parameters are normalized, and
// the garbage value itself passes through verbatim.
func TestNormalizeToolSchemas_FlatToolWithNonObjectFunctionStillNormalized(t *testing.T) {
	body := []byte(`{"tools":[{"name":"f","function":"notdict",` +
		`"parameters":{"properties":{"u":{"enum":["c","f"]}}}}]}`)

	tool := tsnMap(t, tsnTools(t, NormalizeToolSchemas(body), 1)[0], "tools[0]")
	if tool["function"] != "notdict" {
		t.Errorf("garbage function value changed: %v", tool["function"])
	}
	params := tsnMap(t, tool["parameters"], "parameters")
	if got := tsnType(t, params, "parameters"); got != "object" {
		t.Errorf("parameters type = %q, want object", got)
	}
	u := tsnMap(t, tsnMap(t, params["properties"], "properties")["u"], "u")
	if got := tsnType(t, u, "u"); got != "string" {
		t.Errorf("u type = %q, want string", got)
	}
}

// Pins the converse rule: an object "function" wrapper claims the entry as
// chat-shape, so a stray top-level "parameters" beside it is not a
// recognized schema home and stays untouched — an entry's two possible
// OpenAI parameter homes are never both repaired.
func TestNormalizeToolSchemas_ObjectFunctionWrapperClaimsEntry(t *testing.T) {
	body := []byte(`{"tools":[{` +
		`"function":{"name":"f","parameters":{"properties":{"a":{"enum":["x"]}}}},` +
		`"parameters":{"properties":{"b":{"enum":["y"]}}}}]}`)

	tool := tsnMap(t, tsnTools(t, NormalizeToolSchemas(body), 1)[0], "tools[0]")
	// The wrapped parameters are normalized...
	fnParams := tsnMap(t, tsnMap(t, tool["function"], "function")["parameters"], "function.parameters")
	if got := tsnType(t, fnParams, "function.parameters"); got != "object" {
		t.Errorf("function.parameters type = %q, want object", got)
	}
	a := tsnMap(t, tsnMap(t, fnParams["properties"], "function properties")["a"], "a")
	if got := tsnType(t, a, "a"); got != "string" {
		t.Errorf("function.parameters a type = %q, want string", got)
	}
	// ...the stray top-level ones are passed through untouched.
	topParams := tsnMap(t, tool["parameters"], "top-level parameters")
	if v, ok := topParams["type"]; ok {
		t.Errorf("stray top-level parameters gained a type: %v", v)
	}
	b := tsnMap(t, tsnMap(t, topParams["properties"], "top-level properties")["b"], "b")
	if v, ok := b["type"]; ok {
		t.Errorf("stray top-level property gained a type: %v", v)
	}
}

// Anthropic Messages tool: the JSON-Schema lives under "input_schema"
// (served via /v1/messages). Same template crash class; nullable array types
// collapse and recursion reaches nested properties and items.
func TestNormalizeToolSchemas_AnthropicInputSchemaNormalized(t *testing.T) {
	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}],` +
		`"tools":[{"name":"get_weather","description":"Get weather",` +
		`"input_schema":{"type":["object","null"],"properties":{` +
		`"city":{"type":["string","null"],"description":"city"},` +
		`"days":{"type":"array","items":{"type":["integer","null"]}},` +
		`"unit":{"enum":["c","f"]}}}}]}`)

	tool := tsnMap(t, tsnTools(t, NormalizeToolSchemas(body), 1)[0], "tools[0]")
	// The entry's own fields are not schema nodes — identity survives and no
	// type is invented on the tool itself despite its "description" key.
	if tool["name"] != "get_weather" || tool["description"] != "Get weather" {
		t.Errorf("tool identity changed: name=%v description=%v", tool["name"], tool["description"])
	}
	if v, ok := tool["type"]; ok {
		t.Errorf("type invented on the tool entry itself: %v", v)
	}
	schema := tsnMap(t, tool["input_schema"], "input_schema")
	if got := tsnType(t, schema, "input_schema"); got != "object" {
		t.Errorf("input_schema type = %q, want object", got)
	}
	if schema["nullable"] != true {
		t.Errorf("input_schema nullable = %v, want true", schema["nullable"])
	}
	props := tsnMap(t, schema["properties"], "input_schema.properties")
	city := tsnMap(t, props["city"], "city")
	if got := tsnType(t, city, "city"); got != "string" {
		t.Errorf("city type = %q, want string", got)
	}
	if city["nullable"] != true {
		t.Errorf("city nullable = %v, want true", city["nullable"])
	}
	items := tsnMap(t, tsnMap(t, props["days"], "days")["items"], "days.items")
	if got := tsnType(t, items, "days.items"); got != "integer" {
		t.Errorf("days.items type = %q, want integer", got)
	}
	if items["nullable"] != true {
		t.Errorf("days.items nullable = %v, want true", items["nullable"])
	}
	unit := tsnMap(t, props["unit"], "unit")
	if got := tsnType(t, unit, "unit"); got != "string" {
		t.Errorf("unit type = %q, want string", got)
	}
}

// Anthropic entries without input_schema (e.g. server-tool stubs) pass
// through value-equivalent; a schema-carrying sibling is still normalized.
func TestNormalizeToolSchemas_AnthropicToolWithoutInputSchemaUnchanged(t *testing.T) {
	body := []byte(`{"tools":[` +
		`{"type":"web_search_20250305","name":"web_search","max_uses":3},` +
		`{"name":"f","input_schema":{"properties":{"q":{"description":"q"}}}}]}`)

	tools := tsnTools(t, NormalizeToolSchemas(body), 2)
	stub := tsnMap(t, tools[0], "tools[0]")
	want := map[string]any{"type": "web_search_20250305", "name": "web_search", "max_uses": json.Number("3")}
	if !reflect.DeepEqual(stub, want) {
		t.Errorf("schema-less tool changed: %#v, want %#v", stub, want)
	}
	schema := tsnMap(t, tsnMap(t, tools[1], "tools[1]")["input_schema"], "tools[1].input_schema")
	if got := tsnType(t, schema, "input_schema"); got != "object" {
		t.Errorf("sibling input_schema type = %q, want object", got)
	}
	q := tsnMap(t, tsnMap(t, schema["properties"], "tools[1].properties")["q"], "q")
	if got := tsnType(t, q, "q"); got != "string" {
		t.Errorf("sibling q type = %q, want string", got)
	}
}

// All three shapes plus a malformed scalar in ONE tools array — each entry
// is detected and repaired by its own rule.
func TestNormalizeToolSchemas_MixedShapesInOneToolsArray(t *testing.T) {
	body := []byte(`{"model":"m","tools":[` +
		`{"type":"function","function":{"name":"chat","parameters":{"properties":{"a":{"type":["string","null"]}}}}},` +
		`{"type":"function","name":"flat","parameters":{"properties":{"b":{"enum":["x"]}}}},` +
		`{"name":"anthropic","input_schema":{"type":["object","null"],"properties":{"c":{"description":"c"}}}},` +
		`42]}`)

	tools := tsnTools(t, NormalizeToolSchemas(body), 4)

	chatParams := tsnMap(t, tsnMap(t, tsnMap(t, tools[0], "tools[0]")["function"], "tools[0].function")["parameters"], "chat parameters")
	a := tsnMap(t, tsnMap(t, chatParams["properties"], "chat properties")["a"], "a")
	if got := tsnType(t, a, "a"); got != "string" || a["nullable"] != true {
		t.Errorf("chat a = type %q nullable %v, want string/true", got, a["nullable"])
	}

	flatParams := tsnMap(t, tsnMap(t, tools[1], "tools[1]")["parameters"], "flat parameters")
	if got := tsnType(t, flatParams, "flat parameters"); got != "object" {
		t.Errorf("flat parameters type = %q, want object", got)
	}
	b := tsnMap(t, tsnMap(t, flatParams["properties"], "flat properties")["b"], "b")
	if got := tsnType(t, b, "b"); got != "string" {
		t.Errorf("flat b type = %q, want string", got)
	}

	schema := tsnMap(t, tsnMap(t, tools[2], "tools[2]")["input_schema"], "input_schema")
	if got := tsnType(t, schema, "input_schema"); got != "object" || schema["nullable"] != true {
		t.Errorf("input_schema = type %q nullable %v, want object/true", got, schema["nullable"])
	}
	c := tsnMap(t, tsnMap(t, schema["properties"], "anthropic properties")["c"], "c")
	if got := tsnType(t, c, "c"); got != "string" {
		t.Errorf("anthropic c type = %q, want string", got)
	}

	if tools[3] != json.Number("42") {
		t.Errorf("scalar entry changed: %v (%T)", tools[3], tools[3])
	}
}

// Go-specific: null schema values are preserved verbatim in all three homes.
func TestNormalizeToolSchemas_NullSchemasPreservedAcrossShapes(t *testing.T) {
	body := []byte(`{"tools":[` +
		`{"function":{"name":"chat","parameters":null}},` +
		`{"name":"flat","parameters":null},` +
		`{"name":"anthropic","input_schema":null}]}`)

	tools := tsnTools(t, NormalizeToolSchemas(body), 3)
	fn := tsnMap(t, tsnMap(t, tools[0], "tools[0]")["function"], "tools[0].function")
	if v, ok := fn["parameters"]; !ok || v != nil {
		t.Errorf("chat null parameters = %v (present=%v), want preserved null", v, ok)
	}
	flat := tsnMap(t, tools[1], "tools[1]")
	if v, ok := flat["parameters"]; !ok || v != nil {
		t.Errorf("flat null parameters = %v (present=%v), want preserved null", v, ok)
	}
	anthropic := tsnMap(t, tools[2], "tools[2]")
	if v, ok := anthropic["input_schema"]; !ok || v != nil {
		t.Errorf("anthropic null input_schema = %v (present=%v), want preserved null", v, ok)
	}
}

// Go-specific: idempotency and exact number round-trip (UseNumber) across
// all three shapes at once.
func TestNormalizeToolSchemas_AllShapesIdempotentAndNumbersSurvive(t *testing.T) {
	body := []byte(`{"model":"m","max_tokens":9007199254740993,"tools":[` +
		`{"type":"function","function":{"name":"chat","parameters":` +
		`{"properties":{"a":{"type":["integer","null"],"default":9007199254740993}}}}},` +
		`{"type":"function","name":"flat","parameters":` +
		`{"properties":{"b":{"enum":["x"],"default":0.30000000000000004}}}},` +
		`{"name":"anthropic","input_schema":` +
		`{"properties":{"c":{"type":["number","null"],"default":123456789012345678901234567890.5}}}}]}`)

	once := NormalizeToolSchemas(body)
	if bytes.Equal(once, body) {
		t.Fatal("first pass did not normalize")
	}
	twice := NormalizeToolSchemas(once)
	if !bytes.Equal(once, twice) {
		t.Errorf("not idempotent:\n once: %s\ntwice: %s", once, twice)
	}
	// 2^53+1 appears twice (max_tokens + the chat default) and would mangle
	// to ...992 without UseNumber; the others pin float-precision survival.
	if got := bytes.Count(once, []byte("9007199254740993")); got != 2 {
		t.Errorf("exact literal 9007199254740993 appears %d times, want 2\nout: %s", got, once)
	}
	for _, literal := range []string{"0.30000000000000004", "123456789012345678901234567890.5"} {
		if !bytes.Contains(once, []byte(literal)) {
			t.Errorf("exact literal %s lost\nout: %s", literal, once)
		}
	}
	// And the repairs themselves landed in each shape.
	tools := tsnTools(t, once, 3)
	a := tsnMap(t, tsnMap(t, tsnMap(t, tsnMap(t, tsnMap(t, tools[0], "tools[0]")["function"], "function")["parameters"], "chat parameters")["properties"], "chat properties")["a"], "a")
	if got := tsnType(t, a, "a"); got != "integer" || a["nullable"] != true {
		t.Errorf("chat a = type %q nullable %v, want integer/true", got, a["nullable"])
	}
	b := tsnMap(t, tsnMap(t, tsnMap(t, tsnMap(t, tools[1], "tools[1]")["parameters"], "flat parameters")["properties"], "flat properties")["b"], "b")
	if got := tsnType(t, b, "b"); got != "string" {
		t.Errorf("flat b type = %q, want string", got)
	}
	c := tsnMap(t, tsnMap(t, tsnMap(t, tsnMap(t, tools[2], "tools[2]")["input_schema"], "input_schema")["properties"], "anthropic properties")["c"], "c")
	if got := tsnType(t, c, "c"); got != "number" || c["nullable"] != true {
		t.Errorf("anthropic c = type %q nullable %v, want number/true", got, c["nullable"])
	}
}

// Hardening tests (DAR-130 follow-ups): a depth bound on the recursion so a
// pathological deeply-nested schema can't blow the stack, and a "changed"
// signal so a body needing no repair is returned byte-identically (skipping
// the re-encode).

// tsnDeepPropertiesBody builds a tool body whose parameters schema is a chain
// of `levels` nested objects, each {"properties":{"child": <next> }}, ending
// in an enum-only leaf that WOULD gain a "string" type if it were reached. The
// chain is built inside-out as raw JSON so the nesting is real (not a Go data
// structure the test would have to walk by hand). The outermost object is the
// parameters node itself (processed at depth 0); its first child sits at depth
// 1, and so on, so the leaf lands at depth `levels`.
func tsnDeepPropertiesBody(levels int) []byte {
	// Leaf: an enum-only schema — a recognized schema node with no type, the
	// canonical case that injectDefaultTypes repairs to "string".
	node := `{"enum":["x"]}`
	for i := 0; i < levels; i++ {
		node = `{"properties":{"child":` + node + `}}`
	}
	return []byte(`{"tools":[{"type":"function","function":{"name":"f","parameters":` + node + `}}]}`)
}

// (a) A schema nested far deeper than maxToolSchemaDepth must NOT panic or
// overflow the stack; the shallow part is normalized and the part beyond the
// depth budget is left exactly as-is (which is safe — see maxToolSchemaDepth).
func TestNormalizeToolSchemas_DepthLimitStopsRecursionWithoutPanic(t *testing.T) {
	const levels = maxToolSchemaDepth + 200 // comfortably past the ceiling
	body := tsnDeepPropertiesBody(levels)

	var out []byte
	// A naive unbounded recursion on a sufficiently deep input would overflow
	// the stack and crash the test process; reaching the assertions at all is
	// the core guarantee. (defer/recover would not catch a fatal stack overflow,
	// so the real protection is the depth bound under test, not this guard.)
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("normalization panicked on a deeply-nested schema: %v", r)
			}
		}()
		out = NormalizeToolSchemas(body)
	}()

	// The shallow part WAS repaired, so the body changed and re-encoded.
	if bytes.Equal(out, body) {
		t.Fatal("deeply-nested body was returned unchanged; the shallow part should have normalized")
	}

	// Walk down the properties chain and confirm: nodes above the limit gained
	// a structural "object" type, and the node at the depth limit was left
	// untouched (no type invented beyond the budget).
	node := tsnParams(t, out) // depth 0
	depth := 0
	for {
		props, ok := node["properties"].(map[string]any)
		if !ok {
			break
		}
		// A node that carries properties and was reached within the budget must
		// have been typed "object".
		if depth < maxToolSchemaDepth {
			if got, ok := node["type"].(string); !ok || got != "object" {
				t.Fatalf("node at depth %d type = %v, want object (within budget)", depth, node["type"])
			}
		} else {
			// At or beyond the limit, recursion stopped: no type was injected.
			if _, ok := node["type"]; ok {
				t.Fatalf("node at depth %d gained a type %v; recursion should have stopped at the limit",
					depth, node["type"])
			}
		}
		child, ok := props["child"].(map[string]any)
		if !ok {
			t.Fatalf("missing properties.child at depth %d", depth)
		}
		node = child
		depth++
	}

	// The leaf is the enum-only node; it sits at depth `levels`, far past the
	// limit, so it must NOT have gained a "string" type — proof the deep part
	// was left as-is rather than (impossibly) traversed.
	if _, ok := node["type"]; ok {
		t.Errorf("enum leaf at depth %d gained a type %v; it is past the depth budget and must be untouched",
			depth, node["type"])
	}
	if enum, ok := node["enum"].([]any); !ok || len(enum) != 1 {
		t.Errorf("enum leaf content changed: %v", node["enum"])
	}
}

// A node sitting exactly at the LAST in-budget depth is still normalized; the
// first node past it is not. Pins the boundary so an off-by-one in the depth
// accounting is caught.
func TestNormalizeToolSchemas_DepthLimitBoundaryIsNormalized(t *testing.T) {
	// Leaf at depth maxToolSchemaDepth-1 (the deepest in-budget node) must be
	// repaired; building exactly that many wrapper levels puts the enum leaf
	// one step inside the budget.
	body := tsnDeepPropertiesBody(maxToolSchemaDepth - 1)
	out := NormalizeToolSchemas(body)
	if bytes.Equal(out, body) {
		t.Fatal("boundary body was not normalized")
	}

	node := tsnParams(t, out)
	for i := 0; i < maxToolSchemaDepth-1; i++ {
		props, ok := node["properties"].(map[string]any)
		if !ok {
			t.Fatalf("missing properties at depth %d", i)
		}
		node = tsnMap(t, props["child"], "child")
	}
	// node is now the enum leaf at depth maxToolSchemaDepth-1 (in budget).
	if got, ok := node["type"].(string); !ok || got != "string" {
		t.Errorf("in-budget leaf type = %v, want string", node["type"])
	}
}

// (b) A tools body whose every schema node already carries a string `type`
// needs NO repair, so NormalizeToolSchemas must return the caller's ORIGINAL
// bytes verbatim — skipping the JSON re-encode entirely. The input is
// deliberately written with key order and whitespace the Go encoder would
// rewrite (keys not alphabetized, a space after a colon), so byte-equality
// proves the re-marshal path was not taken.
func TestNormalizeToolSchemas_NoRepairReturnsInputBytesIdentical(t *testing.T) {
	// "tools" precedes "model" (Go's encoder sorts keys, so it would move
	// "model" first), and there is a space after the first colon (the encoder
	// emits none). Every schema node has a string type already.
	body := []byte(`{"tools": [{"type":"function","function":{"name":"f","parameters":` +
		`{"type":"object","properties":{` +
		`"city":{"type":"string","description":"city"},` +
		`"count":{"type":"integer"},` +
		`"opts":{"type":"object","properties":{"verbose":{"type":"boolean"}}},` +
		`"tags":{"type":"array","items":{"type":"string"}}},` +
		`"required":["city"]}}}],"model":"gemma-4-26b"}`)

	out := NormalizeToolSchemas(body)
	if !bytes.Equal(out, body) {
		t.Fatalf("fully-typed body was re-encoded; want byte-identical input.\n in: %s\nout: %s", body, out)
	}
	// Sanity: had it re-encoded, the encoder would have sorted "model" ahead of
	// "tools" and dropped the space — so a byte match really does mean no
	// re-encode. Confirm the distinguishing bytes survived.
	if !bytes.HasPrefix(out, []byte(`{"tools": [`)) {
		t.Errorf("output lost its original key order / spacing: %s", out)
	}
}

// (c) A body that DOES need normalization is still corrected (regression for
// the changed-tracking path — a single missing type must flip `changed` and
// trigger the re-encode that injects it).
func TestNormalizeToolSchemas_RepairNeededStillCorrected(t *testing.T) {
	// The `unit` property is enum-only (no type) — exactly one repair needed.
	body := []byte(`{"model":"m","tools":[{"type":"function","function":{"name":"f",` +
		`"parameters":{"type":"object","properties":{` +
		`"city":{"type":"string"},` +
		`"unit":{"enum":["c","f"]}}}}}]}`)

	out := NormalizeToolSchemas(body)
	if bytes.Equal(out, body) {
		t.Fatal("body needing a repair was returned unchanged")
	}
	props := tsnProps(t, out)
	unit := tsnMap(t, props["unit"], "unit")
	if got := tsnType(t, unit, "unit"); got != "string" {
		t.Errorf("unit type = %q, want string (the injected default)", got)
	}
	// The already-typed sibling is untouched.
	city := tsnMap(t, props["city"], "city")
	if got := tsnType(t, city, "city"); got != "string" {
		t.Errorf("city type = %q, want string (preserved)", got)
	}
}
