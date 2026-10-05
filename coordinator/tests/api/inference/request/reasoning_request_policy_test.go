package request_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestApplyResolvedModelReasoningPolicyPreservesExplicitValuesAndUntouchedBytes(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		model    string
		service  bool
		provided bool
	}{
		{name: "explicit null", body: `{"model":"qwen","reasoning":null}`, model: fixtureServiceReasoningOptInModel, service: true, provided: true},
		{name: "explicit scalar", body: `{"model":"qwen","reasoning":"malformed"}`, model: fixtureServiceReasoningOptInModel, service: true, provided: true},
		{name: "non-service target", body: `{ "model" : "qwen" }`, model: fixtureServiceReasoningOptInModel},
		{name: "service other model", body: `{ "model" : "other" }`, model: "other", service: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			parsed, err := production.DecodeInferenceJSONObject([]byte(test.body))
			if err != nil {
				t.Fatal(err)
			}
			before, err := production.MarshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if production.ApplyResolvedModelReasoningPolicy(parsed, test.model, test.service, test.provided) {
				t.Fatal("policy reported a mutation")
			}
			after, err := production.MarshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(before) {
				t.Fatalf("parsed changed: got %s, want %s", after, before)
			}
			// A no-op policy leaves the forward body clean, so the caller's exact
			// bytes reach the provider.
			body := production.ForwardBody{Parsed: parsed, Bytes: []byte(test.body)}
			if got, _ := body.Current(); string(got) != test.body {
				t.Fatalf("forward body changed: got %q, want original %q", got, test.body)
			}
		})
	}
}
