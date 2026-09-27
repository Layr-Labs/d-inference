package e2e

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// Native cache activity and accepted receipts do not imply consumer-visible
// usage is complete. Compare the HTTP details with the validated terminal.
func validateFlashNextCacheUsage(row connectedCase) error {
	var native protocol.UsageInfo
	terminals := 0
	for _, event := range row.Wire {
		if event.Type != "inference_complete" {
			continue
		}
		if err := json.Unmarshal(event.Fields["usage"], &native); err != nil {
			return err
		}
		terminals++
	}
	if terminals != 1 {
		return fmt.Errorf("expected one native usage terminal, got %d", terminals)
	}
	var client struct {
		Prompt struct {
			Cached int `json:"cached_tokens"`
		} `json:"prompt_tokens_details"`
		Completion struct {
			Reasoning int `json:"reasoning_tokens"`
		} `json:"completion_tokens_details"`
	}
	if err := json.Unmarshal(row.HTTP.Usage, &client); err != nil {
		return err
	}
	if client.Prompt.Cached != native.CachedTokens || client.Completion.Reasoning != native.ReasoningTokens {
		return fmt.Errorf("HTTP cached/reasoning details %d/%d differ from native terminal %d/%d",
			client.Prompt.Cached, client.Completion.Reasoning, native.CachedTokens, native.ReasoningTokens)
	}
	return nil
}

func TestFlashNextCacheUsageDetails(t *testing.T) {
	for _, tc := range []struct {
		name, http        string
		cached, reasoning int
		valid             bool
	}{
		{"cold", `{}`, 0, 0, true},
		{"cache", `{"prompt_tokens_details":{"cached_tokens":4096}}`, 4096, 0, true},
		{"missing_cache", `{}`, 4096, 0, false},
		{"wrong_cache", `{"prompt_tokens_details":{"cached_tokens":99}}`, 4096, 0, false},
		{"reasoning", `{"completion_tokens_details":{"reasoning_tokens":8}}`, 0, 8, true},
		{"missing_reasoning", `{}`, 0, 8, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			usage, err := json.Marshal(protocol.UsageInfo{CachedTokens: tc.cached, ReasoningTokens: tc.reasoning})
			if err != nil {
				t.Fatal(err)
			}
			row := connectedCase{HTTP: connectedStream{Usage: json.RawMessage(tc.http)},
				Wire: []testbed.ProviderWireEvent{{Type: "inference_complete", Fields: map[string]json.RawMessage{"usage": usage}}}}
			if err := validateFlashNextCacheUsage(row); (err == nil) != tc.valid {
				t.Fatalf("valid=%t, error=%v", tc.valid, err)
			}
		})
	}
}
