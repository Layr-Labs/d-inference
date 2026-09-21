package api

import (
	"encoding/json"
	"testing"
)

func TestResponsesUsageCarriesTotalTokens(t *testing.T) {
	for _, test := range []struct {
		name                                  string
		prompt, completion, reasoning, cached uint64
	}{
		{"ordinary", 17, 2, 0, 0},
		{"reasoning-is-a-subset", 17, 35, 31, 0},
		{"cache-is-a-subset", 100, 12, 4, 80},
		{"zero-is-present", 0, 0, 0, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			usage := buildResponsesUsage(test.prompt, test.completion, test.reasoning, test.cached)
			raw, err := json.Marshal(usage)
			if err != nil {
				t.Fatal(err)
			}
			var object map[string]any
			if err := json.Unmarshal(raw, &object); err != nil {
				t.Fatal(err)
			}
			if value, ok := object["total_tokens"]; !ok || value != float64(test.prompt+test.completion) {
				t.Fatalf("total_tokens = %v (present=%t), want %d: %s", value, ok, test.prompt+test.completion, raw)
			}
			if object["input_tokens"] != float64(test.prompt) || object["output_tokens"] != float64(test.completion) {
				t.Fatalf("authoritative counts changed: %s", raw)
			}
			if usage.InputTokensDetail.CachedTokens != int(test.cached) || usage.OutputTokensDetail.ReasoningTokens != int(test.reasoning) {
				t.Fatalf("token details changed: %+v", usage)
			}
		})
	}
}
