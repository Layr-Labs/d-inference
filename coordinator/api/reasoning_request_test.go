package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestParseReasoningRequestDisableShapes(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		body     string
		disabled bool
		suppress bool
	}{
		{name: "unspecified", body: `{"model":"m","messages":[]}`, disabled: false, suppress: false},
		{name: "enabled true", body: `{"reasoning":{"enabled":true}}`, disabled: false, suppress: false},
		{name: "enabled false", body: `{"reasoning":{"enabled":false}}`, disabled: true, suppress: true},
		{name: "effort none", body: `{"reasoning":{"effort":"none"}}`, disabled: true, suppress: true},
		{name: "effort NONE", body: `{"reasoning":{"effort":"NONE"}}`, disabled: true, suppress: true},
		{name: "reasoning_effort none", body: `{"reasoning_effort":"none"}`, disabled: true, suppress: true},
		{name: "max_tokens 0", body: `{"reasoning":{"max_tokens":0}}`, disabled: true, suppress: true},
		{name: "exclude true", body: `{"reasoning":{"exclude":true}}`, disabled: false, suppress: true},
		{name: "include_reasoning false", body: `{"include_reasoning":false}`, disabled: false, suppress: true},
		{name: "enable_thinking false", body: `{"enable_thinking":false}`, disabled: true, suppress: true},
		{name: "chat_template_kwargs", body: `{"chat_template_kwargs":{"enable_thinking":false}}`, disabled: true, suppress: true},
		{name: "reasoning bool false", body: `{"reasoning":false}`, disabled: true, suppress: true},
		{name: "effort high", body: `{"reasoning":{"effort":"high"}}`, disabled: false, suppress: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			policy := parseReasoningRequestFromBody([]byte(tc.body))
			gotDisabled := policy.ThinkingEnabled != nil && !*policy.ThinkingEnabled
			if gotDisabled != tc.disabled {
				t.Fatalf("disabled = %v, want %v (policy=%+v)", gotDisabled, tc.disabled, policy)
			}
			if policy.SuppressOutput != tc.suppress {
				t.Fatalf("suppress = %v, want %v (policy=%+v)", policy.SuppressOutput, tc.suppress, policy)
			}
		})
	}
}

func TestStripReasoningFromSSEChunk(t *testing.T) {
	t.Parallel()
	in := `data: {"choices":[{"delta":{"content":"hi","reasoning":"think","reasoning_content":"think"}}]}`
	out := stripReasoningFromSSEChunk(in)
	if strings.Contains(out, `"reasoning"`) || strings.Contains(out, `"reasoning_content"`) {
		t.Fatalf("reasoning fields still present: %s", out)
	}
	if !strings.Contains(out, `"content":"hi"`) {
		t.Fatalf("content was dropped: %s", out)
	}
	if !strings.HasPrefix(out, "data: ") {
		t.Fatalf("data prefix lost: %s", out)
	}
}

func TestStripReasoningFromCompleteResponse(t *testing.T) {
	t.Parallel()
	obj := map[string]any{
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"content":           "4",
					"reasoning":         "2+2",
					"reasoning_content": "2+2",
				},
			},
		},
	}
	stripReasoningFromCompleteResponse(obj)
	msg := obj["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if _, ok := msg["reasoning"]; ok {
		t.Fatal("reasoning should be deleted")
	}
	if _, ok := msg["reasoning_content"]; ok {
		t.Fatal("reasoning_content should be deleted")
	}
	if msg["content"] != "4" {
		t.Fatalf("content = %v", msg["content"])
	}
}

func TestMaybeStripReasoningSSENoop(t *testing.T) {
	t.Parallel()
	in := `data: {"choices":[{"delta":{"reasoning":"x"}}]}`
	if got := maybeStripReasoningSSE(in, false); got != in {
		t.Fatalf("expected unchanged when suppress=false, got %s", got)
	}
}

func TestNormalizeThenSuppressDropsAliasedReasoning(t *testing.T) {
	t.Parallel()
	in := `data: {"choices":[{"delta":{"reasoning_content":"leaked think"}}]}`
	normalized := normalizeSSEChunk(in)
	if !strings.Contains(normalized, `"reasoning"`) {
		t.Fatalf("normalize should alias reasoning_content: %s", normalized)
	}
	stripped := maybeStripReasoningSSE(normalized, true)
	if strings.Contains(stripped, `"reasoning"`) || strings.Contains(stripped, `"reasoning_content"`) {
		t.Fatalf("suppressed chunk still has reasoning: %s", stripped)
	}
}

func TestStampReasoningPolicy(t *testing.T) {
	t.Parallel()
	pr := &registry.PendingRequest{}
	stampReasoningPolicy(pr, []byte(`{"reasoning":{"effort":"none"}}`))
	if !pr.SuppressReasoningOutput {
		t.Fatal("effort=none should stamp SuppressReasoningOutput")
	}
	pr2 := &registry.PendingRequest{}
	stampReasoningPolicy(pr2, []byte(`{"reasoning":{"enabled":true}}`))
	if pr2.SuppressReasoningOutput {
		t.Fatal("enabled=true should not suppress")
	}
}

func TestParseReasoningRequestPreservesJSONNumberZero(t *testing.T) {
	t.Parallel()
	raw := []byte(`{"reasoning":{"max_tokens":0}}`)
	parsed, err := decodeInferenceJSONObject(raw)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := parsed["reasoning"].(map[string]any)["max_tokens"].(json.Number); !ok {
		t.Fatalf("max_tokens should stay json.Number, got %T", parsed["reasoning"].(map[string]any)["max_tokens"])
	}
	policy := parseReasoningRequest(parsed)
	if policy.ThinkingEnabled == nil || *policy.ThinkingEnabled {
		t.Fatalf("max_tokens 0 should disable thinking: %+v", policy)
	}
}
