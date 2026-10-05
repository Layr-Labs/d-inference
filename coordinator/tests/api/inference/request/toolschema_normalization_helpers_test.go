package request_test

import (
	"bytes"
	"encoding/json"
	"testing"
)

// publicTsnDecode decodes a body with UseNumber (matching the implementation) and
// asserts it is a JSON object.
func publicTsnDecode(t *testing.T, body []byte) map[string]any {
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

// publicTsnMap asserts v is a JSON object.
func publicTsnMap(t *testing.T, v any, what string) map[string]any {
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
	root := publicTsnDecode(t, body)
	tools, ok := root["tools"].([]any)
	if !ok || len(tools) != wantLen {
		t.Fatalf("tools = %v (%T), want array of %d", root["tools"], root["tools"], wantLen)
	}
	return tools
}

// publicTsnFirstToolFn returns tools[0].function from a body.
func publicTsnFirstToolFn(t *testing.T, body []byte) map[string]any {
	t.Helper()
	root := publicTsnDecode(t, body)
	tools, ok := root["tools"].([]any)
	if !ok || len(tools) == 0 {
		t.Fatalf("tools is %T (%v), want non-empty array", root["tools"], root["tools"])
	}
	return publicTsnMap(t, publicTsnMap(t, tools[0], "tools[0]")["function"], "tools[0].function")
}

// publicTsnParams returns tools[0].function.parameters.
func publicTsnParams(t *testing.T, body []byte) map[string]any {
	t.Helper()
	return publicTsnMap(t, publicTsnFirstToolFn(t, body)["parameters"], "parameters")
}

// publicTsnProps returns tools[0].function.parameters.properties.
func publicTsnProps(t *testing.T, body []byte) map[string]any {
	t.Helper()
	return publicTsnMap(t, publicTsnParams(t, body)["properties"], "parameters.properties")
}

// publicTsnType asserts the node's `type` is a string and returns it.
func publicTsnType(t *testing.T, node map[string]any, what string) string {
	t.Helper()
	s, ok := node["type"].(string)
	if !ok {
		t.Fatalf("%s type is %T (%v), want string", what, node["type"], node["type"])
	}
	return s
}
