package request

import (
	"testing"
)

func TestApplyResolvedModelReasoningPolicyPreservesExplicitValuesAndUntouchedBytes(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		model    string
		service  bool
		provided bool
	}{
		{name: "explicit null", body: `{"model":"qwen","reasoning":null}`, model: serviceReasoningOptInModel, service: true, provided: true},
		{name: "explicit scalar", body: `{"model":"qwen","reasoning":"malformed"}`, model: serviceReasoningOptInModel, service: true, provided: true},
		{name: "non-service target", body: `{ "model" : "qwen" }`, model: serviceReasoningOptInModel},
		{name: "service other model", body: `{ "model" : "other" }`, model: "other", service: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			parsed, err := DecodeInferenceJSONObject([]byte(test.body))
			if err != nil {
				t.Fatal(err)
			}
			before, err := MarshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if ApplyResolvedModelReasoningPolicy(parsed, test.model, test.service, test.provided) {
				t.Fatal("policy reported a mutation")
			}
			after, err := MarshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(before) {
				t.Fatalf("parsed changed: got %s, want %s", after, before)
			}
			// A no-op policy leaves the forward body clean, so the caller's exact
			// bytes reach the provider.
			body := ForwardBody{Parsed: parsed, Bytes: []byte(test.body)}
			if got, _ := body.Current(); string(got) != test.body {
				t.Fatalf("forward body changed: got %q, want original %q", got, test.body)
			}
		})
	}
}
