package api

// Tests for the privacy-safe "service request shape" field builder
// (request_shape_telemetry.go). The two properties defended:
//
//  1. Enum normalization: every string field lands in its closed set, with
//     trim/case tolerance for recognized values.
//  2. Privacy: an unrecognized consumer-supplied string maps to "other" and
//     the raw value NEVER appears anywhere in the emitted fields.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// parseShapeBody decodes a JSON body the way parseInferencePrelude does
// (UseNumber), so tests exercise the same value types the handler sees.
func parseShapeBody(t *testing.T, body string) map[string]any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader([]byte(body)))
	dec.UseNumber()
	var parsed map[string]any
	if err := dec.Decode(&parsed); err != nil {
		t.Fatalf("parse body: %v", err)
	}
	return parsed
}

// fieldMap folds the alternating key/value slog args into a map and asserts
// the list is well-formed (even length, string keys, no duplicate keys).
func fieldMap(t *testing.T, fields []any) map[string]any {
	t.Helper()
	if len(fields)%2 != 0 {
		t.Fatalf("odd field list length %d", len(fields))
	}
	m := make(map[string]any, len(fields)/2)
	for i := 0; i < len(fields); i += 2 {
		k, ok := fields[i].(string)
		if !ok {
			t.Fatalf("field key %d is %T, want string", i, fields[i])
		}
		if _, dup := m[k]; dup {
			t.Fatalf("duplicate field key %q", k)
		}
		m[k] = fields[i+1]
	}
	return m
}

func shapeFields(t *testing.T, body string) map[string]any {
	t.Helper()
	return fieldMap(t, serviceRequestShapeFields(parseShapeBody(t, body), requestShapeComputed{
		traceID:               "trace-1",
		model:                 "build-model",
		publicModel:           "public-model",
		stream:                true,
		estimatedPromptTokens: 100,
		requestedMaxTokens:    2048,
		hasTools:              false,
		requiresVision:        false,
	}))
}

func TestServiceRequestShapeFields_ReasoningEnabled(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"true", `{"reasoning":{"enabled":true}}`, "true"},
		{"false", `{"reasoning":{"enabled":false}}`, "false"},
		{"non_bool string", `{"reasoning":{"enabled":"yes"}}`, "non_bool"},
		{"non_bool number", `{"reasoning":{"enabled":1}}`, "non_bool"},
		{"enabled key missing", `{"reasoning":{"effort":"high"}}`, "absent"},
		{"reasoning missing", `{}`, "absent"},
		{"reasoning not an object", `{"reasoning":true}`, "absent"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shapeFields(t, tc.body)
			if got["reasoning_enabled"] != tc.want {
				t.Errorf("reasoning_enabled = %v, want %q", got["reasoning_enabled"], tc.want)
			}
		})
	}

	// reasoning_present tracks the key independently of shape.
	if got := shapeFields(t, `{"reasoning":true}`); got["reasoning_present"] != true {
		t.Errorf("reasoning_present = %v, want true for non-object reasoning", got["reasoning_present"])
	}
	if got := shapeFields(t, `{}`); got["reasoning_present"] != false {
		t.Errorf("reasoning_present = %v, want false when missing", got["reasoning_present"])
	}
}

func TestServiceRequestShapeFields_ReasoningEffort(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"nested low", `{"reasoning":{"effort":"low"}}`, "low"},
		{"nested trims and lowercases", `{"reasoning":{"effort":"  HIGH "}}`, "high"},
		{"top-level medium", `{"reasoning_effort":"medium"}`, "medium"},
		{"top-level mixed case", `{"reasoning_effort":"XHigh"}`, "xhigh"},
		{"none", `{"reasoning_effort":"none"}`, "none"},
		{"minimal", `{"reasoning_effort":"minimal"}`, "minimal"},
		{"max", `{"reasoning_effort":"max"}`, "max"},
		{"nested wins over top-level", `{"reasoning":{"effort":"low"},"reasoning_effort":"high"}`, "low"},
		{"unknown string", `{"reasoning_effort":"turbo-secret-v2"}`, "other"},
		{"non-string", `{"reasoning_effort":3}`, "other"},
		{"nested non-string", `{"reasoning":{"effort":true}}`, "other"},
		{"absent", `{}`, "absent"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shapeFields(t, tc.body)
			if got["reasoning_effort"] != tc.want {
				t.Errorf("reasoning_effort = %v, want %q", got["reasoning_effort"], tc.want)
			}
		})
	}
}

func TestServiceRequestShapeFields_IncludeReasoning(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"true", `{"include_reasoning":true}`, "true"},
		{"false", `{"include_reasoning":false}`, "false"},
		{"absent", `{}`, "absent"},
		{"non-bool collapses to absent", `{"include_reasoning":"true"}`, "absent"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shapeFields(t, tc.body)
			if got["include_reasoning"] != tc.want {
				t.Errorf("include_reasoning = %v, want %q", got["include_reasoning"], tc.want)
			}
		})
	}
}

func TestServiceRequestShapeFields_ResponseFormat(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"json_schema object", `{"response_format":{"type":"json_schema","json_schema":{"name":"x"}}}`, "json_schema"},
		{"json_object object", `{"response_format":{"type":"json_object"}}`, "json_object"},
		{"text object", `{"response_format":{"type":"text"}}`, "text"},
		{"bare string", `{"response_format":"json_object"}`, "json_object"},
		{"case/space tolerant", `{"response_format":{"type":" JSON_SCHEMA "}}`, "json_schema"},
		{"unknown type", `{"response_format":{"type":"grammar"}}`, "other"},
		{"object without type", `{"response_format":{}}`, "other"},
		{"non-string type", `{"response_format":{"type":7}}`, "other"},
		{"unrecognized shape", `{"response_format":42}`, "other"},
		{"absent", `{}`, "absent"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shapeFields(t, tc.body)
			if got["response_format"] != tc.want {
				t.Errorf("response_format = %v, want %q", got["response_format"], tc.want)
			}
		})
	}
}

func TestServiceRequestShapeFields_NumbersPassedThrough(t *testing.T) {
	got := shapeFields(t, `{"temperature":0.7,"top_p":0.95,"presence_penalty":-1,"frequency_penalty":2}`)
	for key, want := range map[string]float64{
		"temperature":       0.7,
		"top_p":             0.95,
		"presence_penalty":  -1,
		"frequency_penalty": 2,
	} {
		v, ok := got[key].(float64)
		if !ok || v != want {
			t.Errorf("%s = %v (%T), want %v", key, got[key], got[key], want)
		}
	}
}

func TestServiceRequestShapeFields_NonNumberSamplingParamsAbsent(t *testing.T) {
	// String-typed (or otherwise non-number) sampling params must not appear
	// at all — no coercion, no raw echo.
	got := shapeFields(t, `{"temperature":"0.7","top_p":null,"presence_penalty":{"v":1}}`)
	for _, key := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty"} {
		if _, present := got[key]; present {
			t.Errorf("%s present = %v, want key omitted", key, got[key])
		}
	}
}

func TestServiceRequestShapeFields_PresenceFlagsAndCounts(t *testing.T) {
	got := shapeFields(t, `{
		"seed": 42,
		"logprobs": true,
		"chat_template_kwargs": {"enable_thinking": false},
		"tools": [{"type":"function"},{"type":"function"}],
		"n": 1
	}`)
	for key, want := range map[string]any{
		"seed_present":             true,
		"logprobs_present":         true,
		"has_chat_template_kwargs": true,
		"tool_count":               2,
		"n":                        1,
	} {
		if got[key] != want {
			t.Errorf("%s = %v, want %v", key, got[key], want)
		}
	}

	got = shapeFields(t, `{}`)
	for key, want := range map[string]any{
		"seed_present":             false,
		"logprobs_present":         false,
		"has_chat_template_kwargs": false,
		"tool_count":               0,
		"n":                        0,
	} {
		if got[key] != want {
			t.Errorf("empty body: %s = %v, want %v", key, got[key], want)
		}
	}
}

func TestServiceRequestShapeFields_ComputedValuesEchoed(t *testing.T) {
	fields := serviceRequestShapeFields(parseShapeBody(t, `{}`), requestShapeComputed{
		traceID:               "trace-abc",
		model:                 "qwen3-32b-fp8",
		publicModel:           "qwen3-32b",
		stream:                true,
		estimatedPromptTokens: 1234,
		requestedMaxTokens:    4096,
		hasTools:              true,
		requiresVision:        true,
	})
	got := fieldMap(t, fields)
	for key, want := range map[string]any{
		"trace_id":                "trace-abc",
		"model":                   "qwen3-32b-fp8",
		"public_model":            "qwen3-32b",
		"stream":                  true,
		"estimated_prompt_tokens": 1234,
		"requested_max_tokens":    4096,
		"has_tools":               true,
		"requires_vision":         true,
	} {
		if got[key] != want {
			t.Errorf("%s = %v, want %v", key, got[key], want)
		}
	}
}

// TestServiceRequestShapeFields_NoRawValueLeakage is the privacy contract:
// distinctive consumer-supplied strings anywhere in the body must never
// surface in the emitted fields.
func TestServiceRequestShapeFields_NoRawValueLeakage(t *testing.T) {
	const marker = "SECRET_MARKER_9f8e7d"
	body := fmt.Sprintf(`{
		"messages": [{"role":"user","content":"%[1]s"}],
		"reasoning": {"effort":"%[1]s","enabled":"%[1]s"},
		"reasoning_effort": "%[1]s",
		"include_reasoning": "%[1]s",
		"response_format": {"type":"%[1]s"},
		"temperature": "%[1]s",
		"chat_template_kwargs": {"key":"%[1]s"},
		"tools": [{"type":"function","function":{"name":"%[1]s"}}],
		"seed": "%[1]s",
		"logprobs": "%[1]s"
	}`, marker)
	fields := serviceRequestShapeFields(parseShapeBody(t, body), requestShapeComputed{
		traceID: "trace-1", model: "m", publicModel: "p",
	})
	rendered := fmt.Sprintf("%v", fields)
	if strings.Contains(rendered, marker) {
		t.Fatalf("raw consumer value leaked into shape fields: %s", rendered)
	}
	got := fieldMap(t, fields)
	if got["reasoning_effort"] != "other" {
		t.Errorf("reasoning_effort = %v, want other", got["reasoning_effort"])
	}
	if got["response_format"] != "other" {
		t.Errorf("response_format = %v, want other", got["response_format"])
	}
	if got["reasoning_enabled"] != "non_bool" {
		t.Errorf("reasoning_enabled = %v, want non_bool", got["reasoning_enabled"])
	}
}
