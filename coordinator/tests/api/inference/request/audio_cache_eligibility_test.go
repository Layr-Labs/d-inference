package request_test

import (
	"encoding/json"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func audioCacheBodies() []string {
	return []string{
		`{"messages":[{"role":"user","content":[{"type":"text","text":"describe"},{"type":"input_audio","input_audio":{"data":"AAAA","format":"wav"}}]}]}`,
		`{"messages":[{"role":"user","content":[{"type":"input_audio"}]}]}`,
		`{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":null}]}]}`,
		`{"messages":[{"role":"tool","tool_call_id":"c","content":[{"type":"audio_url","audio_url":42}]}]}`,
		`{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"AAAA","format":"mp3"}}]}]}`,
		`{"input":[{"type":"message","role":"user","content":[{"type":"audio_url","audio_url":{"url":"https://example.invalid/private"}}]}]}`,
		`{"input":[{"type":"function_call_output","call_id":"c","output":[{"type":"input_audio","input_audio":null}]}]}`,
		`{"input":[{"type":"function_call_output","call_id":"c","output":{"type":"audio_url"}}]}`,
		`{"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","content":[{"type":"input_audio"}]}]}]}`,
	}
}

func TestAudioCachePresenceDoesNotChangeVisionOrEstimates(t *testing.T) {
	for _, body := range audioCacheBodies() {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		before, err := json.Marshal(parsed)
		if err != nil {
			t.Fatal(err)
		}
		if !production.CachePlanHasMedia(false, parsed) || !production.CachePlanHasMedia(false, parsed) {
			t.Fatal("declared audio did not close text-cache admission")
		}
		if production.DetectMediaRequirement(parsed) || production.CountMediaParts(parsed) != 0 {
			t.Fatal("audio acquired a vision requirement/count")
		}
		// Independent pre-existing estimators: cache classification is not a
		// new routing price and must never replace the billing byte bound.
		routing, billing, media := legacyEstimates(parsed)
		shape := production.IntrospectRequest(parsed)
		if shape.RoutingPromptTokens(parsed) != routing ||
			shape.BillingPromptTokens(parsed) != billing || media != 0 {
			t.Fatal("audio cache detection changed routing/billing/vision estimates")
		}
		after, err := json.Marshal(parsed)
		if err != nil || string(before) != string(after) {
			t.Fatal("presence classification mutated request bytes")
		}
	}
}

func TestAudioCachePresenceIgnoresWordsSchemasAndArguments(t *testing.T) {
	for _, body := range []string{
		`{"messages":[{"role":"user","content":"input_audio audio_url"}]}`,
		`{"messages":[{"role":"user","content":[{"type":"text","text":"{\"type\":\"input_audio\"}"}]}]}`,
		`{"messages":[{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"f","arguments":"{\"type\":\"input_audio\"}"}}]}],"tools":[{"type":"function","function":{"parameters":{"type":"audio_url"}}}]}`,
		`{"input":[{"type":"function_call","name":"f","arguments":{"type":"input_audio"}},{"type":"function_call_output","call_id":"c","output":"audio_url"}]}`,
		`{"messages":[{"role":"user","content":"plain"}],"metadata":{"content":{"type":"audio_url"}}}`,
		`{"prompt":"input_audio audio_url"}`,
	} {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		if production.CachePlanHasMedia(false, parsed) || production.CachePlanHasMedia(false, parsed) {
			t.Fatal("non-content audio words became cache media")
		}
		if !production.CachePlanHasMedia(true, parsed) {
			t.Fatal("existing visual cache exclusion was weakened")
		}
	}
}
