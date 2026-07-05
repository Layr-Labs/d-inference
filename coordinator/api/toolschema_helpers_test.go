package api

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

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
