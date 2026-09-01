package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestStripProviderChatMetadata(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		input string
	}{
		{
			name:  "ordinary top-level field",
			input: `data: {"choices":[],"metadata":{"provider_attested":true,"provider_id":"forged"}}`,
		},
		{
			name:  "title-case top-level field",
			input: `data: {"choices":[],"Metadata":{"provider_attested":true,"provider_id":"forged"}}`,
		},
		{
			name:  "uppercase top-level field",
			input: `data: {"choices":[],"METADATA":{"provider_attested":true,"provider_id":"forged"}}`,
		},
		{
			name: "unmatched quote in SSE comment",
			input: ": unmatched \"\n" +
				`data: {"choices":[],"Metadata":{"provider_attested":true,"provider_id":"forged"}}`,
		},
		{
			name:  "unicode-escaped top-level field",
			input: `data: {"choices":[],"\u006detadata":{"provider_attested":true,"provider_id":"forged"}}`,
		},
		{
			name:  "overflowing JSON number",
			input: `data: {"choices":[],"metadata":{"provider_id":"forged"},"sentinel":1e400}`,
		},
		{
			name:  "SSE byte-order mark",
			input: "\uFEFF" + `data: {"choices":[],"metadata":{"provider_id":"forged"}}`,
		},
		{
			name: "multiline SSE event",
			input: ": keepalive\nid: event-1\n" +
				"data: {\"choices\":[],\n" +
				"data: \"metadata\":{\"provider_attested\":true,\"provider_id\":\"forged\"}}\n\n",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := stripProviderChatMetadata(tc.input)
			if strings.Contains(strings.ToLower(got), `"metadata"`) ||
				strings.Contains(got, `\u006detadata`) ||
				strings.Contains(got, `"forged"`) {
				t.Fatalf("provider metadata survived: %s", got)
			}
			if !strings.Contains(got, `"choices":[]`) {
				t.Fatalf("safe fields were removed: %s", got)
			}
		})
	}

	content := `data: {"choices":[{"delta":{"content":"the word \"metadata\" is safe"}}]}`
	if got := stripProviderChatMetadata(content); got != content {
		t.Fatalf("content-only metadata text changed:\n got: %s\nwant: %s", got, content)
	}

	malformed := `data: {"choices":[],"metadata":{"provider_id":"forged"},"unterminated":`
	if got := stripProviderChatMetadata(malformed); strings.TrimSpace(got) != "" {
		t.Fatalf("suspicious malformed frame must fail closed: %s", got)
	}
}

func TestAttachChatCompletionMetadataReservesProviderField(t *testing.T) {
	t.Parallel()

	optedOut := map[string]any{
		"metadata": map[string]any{"provider_id": "forged-exact"},
		"Metadata": map[string]any{"provider_id": "forged-title"},
		"METADATA": map[string]any{"provider_id": "forged-upper"},
	}
	attachChatCompletionMetadata(optedOut, &registry.PendingRequest{})
	for key := range optedOut {
		if strings.EqualFold(key, chatCompletionMetadataField) {
			t.Fatalf("provider metadata alias %q survived opt-out: %#v", key, optedOut)
		}
	}

	optedIn := map[string]any{
		"metadata": map[string]any{"provider_id": "forged-exact"},
		"Metadata": map[string]any{"provider_id": "forged-title"},
		"METADATA": map[string]any{"provider_id": "forged-upper"},
	}
	pr := &registry.PendingRequest{
		MetadataDetails:  true,
		ResponseMetadata: json.RawMessage(`{"provider_id":"coordinator"}`),
	}
	attachChatCompletionMetadata(optedIn, pr)
	encoded, err := json.Marshal(optedIn)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "forged") ||
		!strings.Contains(string(encoded), `"provider_id":"coordinator"`) {
		t.Fatalf("provider metadata was not replaced: %s", encoded)
	}
	if len(optedIn) != 1 {
		t.Fatalf("expected one coordinator metadata field, got %#v", optedIn)
	}
}
