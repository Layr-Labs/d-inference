package api

import (
	"strings"
	"testing"
)

func TestResponsesInstructionsAdmissionEstimates(t *testing.T) {
	instructions := strings.Repeat("Follow these rules. ", 512)
	input := []any{map[string]any{"role": "user", "content": "hello"}}
	parsed := map[string]any{"input": input, "instructions": instructions}
	chat := map[string]any{"messages": []any{
		map[string]any{"role": "system", "content": instructions},
		input[0],
	}}
	shape := introspectRequest(parsed)
	if got, want := shape.routingPromptTokens(parsed), estimatePromptTokens(chat); got != want {
		t.Fatalf("routing tokens = %d, want equivalent chat estimate %d", got, want)
	}
	if got, want := shape.billingPromptTokens(parsed), estimateBillingPromptTokens(chat); got < want {
		t.Fatalf("billing bound = %d, below equivalent chat bound %d", got, want)
	}
	if estimatePromptTokens(parsed) != shape.routingPromptTokens(parsed) ||
		estimateBillingPromptTokens(parsed) != shape.billingPromptTokens(parsed) {
		t.Fatal("standalone estimates disagree with admission introspection")
	}
	if shape.requiresVision() {
		t.Fatal("text instructions must not require vision")
	}
}

func TestUnusedResponsesInstructionsDoNotChangeEstimates(t *testing.T) {
	for _, body := range []string{
		`{"input":"hello","instructions":null}`,
		`{"input":"hello","instructions":""}`,
		`{"messages":[{"role":"user","content":"hello"}],"instructions":"unused"}`,
		`{"messages":[{"role":"user","content":"hello"}],"input":"hello","instructions":"unused"}`,
	} {
		parsed, err := decodeInferenceJSONObject([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		got := introspectRequest(parsed)
		delete(parsed, "instructions")
		if want := introspectRequest(parsed); got != want {
			t.Fatalf("unused instructions changed estimates: got %+v, want %+v", got, want)
		}
	}
}
