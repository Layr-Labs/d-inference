package inference_test

import (
	"encoding/json"
	"testing"
)

func TestCachePlanningComposedPrivacyOracleControls(t *testing.T) {
	const valid = `{"model":"fixture","messages":[{"role":"user","content":"nested-user-value nested-metadata-value"}],"cache_control":{"type":"ephemeral","metadata":{"user":"nested-cache-value"}}}`
	if err := privacyPlanningBodyError([]byte(valid)); err != nil {
		t.Fatal(err)
	}
	for _, mutation := range []string{"user_empty", "metadata_null", "safety_identifier_empty", "caller_cache_key",
		"nested_removed", "semantic_removed", "invalid_json"} {
		t.Run(mutation, func(t *testing.T) {
			var body map[string]any
			if err := json.Unmarshal([]byte(valid), &body); err != nil {
				t.Fatal(err)
			}
			switch mutation {
			case "user_empty":
				body["user"] = ""
			case "metadata_null":
				body["metadata"] = nil
			case "safety_identifier_empty":
				body["safety_identifier"] = ""
			case "caller_cache_key":
				body["prompt_cache_key"] = "must-not-forward-cache-key"
			case "nested_removed":
				delete(body["cache_control"].(map[string]any), "metadata")
			case "semantic_removed":
				body["messages"] = []any{}
			}
			encoded, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			if mutation == "invalid_json" {
				encoded = []byte(`{"model":`)
			}
			if privacyPlanningBodyError(encoded) == nil {
				t.Fatal("privacy/body oracle accepted its negative control")
			}
		})
	}
}
