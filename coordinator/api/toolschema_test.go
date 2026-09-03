package api

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"
)

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
