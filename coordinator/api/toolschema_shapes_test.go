package api

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"
)

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

// The enum leaf at depth 63 is the last node inside the current traversal
// budget; the otherwise identical leaf at depth 64 is the first node that must
// remain untouched. Keep the literal ceiling pinned here: silently raising it
// would re-open unbounded-work risk, while lowering it would stop normalizing a
// previously accepted schema.
func TestNormalizeToolSchemas_DepthLimitBoundary(t *testing.T) {
	const currentDepthCeiling = 64
	if maxToolSchemaDepth != currentDepthCeiling {
		t.Fatalf("maxToolSchemaDepth = %d, want the pinned ceiling %d", maxToolSchemaDepth, currentDepthCeiling)
	}

	tests := []struct {
		name         string
		levels       int
		wantLeafType bool
	}{
		{name: "exact accepted boundary", levels: currentDepthCeiling - 1, wantLeafType: true},
		{name: "one beyond boundary", levels: currentDepthCeiling, wantLeafType: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := tsnDeepPropertiesBody(tt.levels)
			out := NormalizeToolSchemas(body)
			if bytes.Equal(out, body) {
				t.Fatal("outer in-budget nodes were not normalized")
			}

			node := tsnParams(t, out)
			for depth := range tt.levels {
				props, ok := node["properties"].(map[string]any)
				if !ok {
					t.Fatalf("missing properties at depth %d", depth)
				}
				node = tsnMap(t, props["child"], "child")
			}

			got, hasType := node["type"].(string)
			if tt.wantLeafType {
				if !hasType || got != "string" {
					t.Errorf("leaf at depth %d type = %v, want string", tt.levels, node["type"])
				}
			} else if _, exists := node["type"]; exists {
				t.Errorf("leaf at depth %d gained type %v beyond the traversal ceiling", tt.levels, node["type"])
			}
			if enum, ok := node["enum"].([]any); !ok || len(enum) != 1 || enum[0] != "x" {
				t.Errorf("leaf at depth %d content changed: %v", tt.levels, node["enum"])
			}
		})
	}
}
