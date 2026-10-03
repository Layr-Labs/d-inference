package request_test

import (
	"bytes"
	"encoding/json"
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
