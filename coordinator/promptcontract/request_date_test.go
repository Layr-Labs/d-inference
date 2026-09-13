package promptcontract

import (
	"encoding/json"
	"testing"
	"time"
)

func TestRequestDateSurvivesLoweringAndNextDayRetry(t *testing.T) {
	// The provider may be in a different timezone, and a retry can cross UTC
	// midnight. Lowering must preserve the captured value instead of reading time.
	received := time.Date(2028, 3, 1, 1, 59, 59, 0, time.FixedZone("east", 2*3600))
	for endpoint, input := range map[Endpoint]map[string]any{
		EndpointChatCompletions: {"messages": []any{map[string]any{"role": "user", "content": "hello"}}},
		EndpointResponses:       {"input": "hello"},
		EndpointCompletions:     {"prompt": "hello"},
		EndpointMessages:        {"messages": []any{map[string]any{"role": "user", "content": "hello"}}},
	} {
		t.Run(string(endpoint), func(t *testing.T) {
			input["model"] = "gpt-oss"
			input[RequestDateField] = "forged"
			SetRequestDate(input, received)
			body, err := json.Marshal(input)
			if err != nil {
				t.Fatal(err)
			}
			lowered, err := LowerProviderBody(endpoint, body)
			if err != nil {
				t.Fatal(err)
			}
			// A retry starts from the already lowered provider body.
			retry, err := LowerProviderBody(EndpointChatCompletions, lowered)
			if err != nil {
				t.Fatal(err)
			}
			var parsed map[string]any
			if err := json.Unmarshal(retry, &parsed); err != nil {
				t.Fatal(err)
			}
			if parsed[RequestDateField] != "2028-02-29" {
				t.Fatalf("request date changed across lowering/retry: %v", parsed[RequestDateField])
			}
			SetRequestDate(input, received.Add(time.Second))
			if input[RequestDateField] != "2028-03-01" {
				t.Fatal("new request did not capture its own UTC day")
			}
		})
	}
}
