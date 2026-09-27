package api

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"testing"
)

// These are curated synthetic validation bodies. They deliberately contain no
// endpoint, credential, request ID, or inferred native artifact. Canonical JSON
// hashes identify field values, not the display transcript's original wire bytes.
const orIncidentAlias = "nvidia-nemotron-3.5-lightning"
const orIncidentBuild = "EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp"

// The known build string is a fake registration identity only. No artifact is
// loaded; this does not identify the actual build used by the historical request.
const orIncidentOmitted = `{"messages":[{"content":"What is the weather like in Boston, MA in fahrenheit?","role":"user"}],"reasoning":{"enabled":false},"stream":true,"tools":[{"function":{"description":"Get the current weather in a given location","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"},"strict":true},"type":"function"}]}`
const orIncidentAuto = `{"messages":[{"content":"What is the weather like in Boston, MA in fahrenheit?","role":"user"}],"reasoning":{"enabled":false},"stream":true,"tool_choice":"auto","tools":[{"function":{"description":"Get the current weather in a given location","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"},"strict":true},"type":"function"}]}`

func orIncidentRequest(t *testing.T, original string) map[string]any {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal([]byte(original), &body); err != nil {
		t.Fatal(err)
	}
	// Explicit fixture wrapper: model is absent in the captured provider request.
	body["model"] = orIncidentAlias
	return body
}
func orJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestOpenRouterConformanceIncidentProvenance(t *testing.T) {
	for _, tc := range []struct{ name, body, hash string }{
		{"off_omitted", orIncidentOmitted, "f0f8f60c48d944fb9270c6facfd5cc0c5543fc37b48cce6ef847abe3be8f2150"},
		{"off_auto", orIncidentAuto, "d63598aad05a4e1dda12a82c119616c490de714f1a51328b39eb598b6229844b"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := fmt.Sprintf("%x", sha256.Sum256([]byte(tc.body))); got != tc.hash {
				t.Fatal("curated request changed")
			}
			var body map[string]any
			if err := json.Unmarshal([]byte(tc.body), &body); err != nil {
				t.Fatal(err)
			}
			for _, field := range []string{"model", "max_tokens", "temperature", "top_p", "parallel_tool_calls", "chat_template_kwargs", "stream_options"} {
				if _, ok := body[field]; ok {
					t.Fatalf("original omitted field added: %s", field)
				}
			}
			if _, ok := body["tool_choice"]; ok != (tc.name == "off_auto") {
				t.Fatal("tool_choice presence changed")
			}
		})
	}
}

// Response builders are separate from orWeatherScenario's fixed expectation.
// These are authored replay controls, never generated-model success evidence.
func orIncidentFrame(delta any, finish any) string {
	b, _ := json.Marshal(map[string]any{"id": "incident-fixture-response", "object": "chat.completion.chunk", "created": 1700000000, "model": orIncidentAlias, "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}})
	return "data: " + string(b) + "\n\n"
}
func orIncidentTool(index int, id, name, arguments string) map[string]any {
	return map[string]any{"index": index, "id": id, "type": "function", "function": map[string]any{"name": name, "arguments": arguments}}
}
func orIncidentCalls(calls ...map[string]any) string {
	return orIncidentFrame(map[string]any{"tool_calls": calls}, nil)
}
func orIncidentEnd(reason string) string {
	return orIncidentFrame(map[string]any{}, reason) + "data: [DONE]\n\n"
}
func orWeatherCall() map[string]any {
	return orIncidentTool(0, "call-fixture-weather", "get_current_weather", `{"location":"Boston, MA","unit":"fahrenheit"}`)
}

// The report contains refusal text but not SSE delimiters/DONE. These replay
// strings retain the observed prose; their wire framing and IDs are authored.
const orRefusal39 = "I’m not able to look up current conditions, but you can check the weather in Boston, MA on most weather websites or apps. Let me know if you need help with anything else!"
const orRefusal43 = "I’m not able to look up current conditions, but you can check the weather in Boston, MA on most weather websites or apps. If you tell me what you find, I can help you interpret it!"
