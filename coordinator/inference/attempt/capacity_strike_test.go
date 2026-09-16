package attempt

import (
	"testing"
)

// IsCapacityRejectStrike must count node-scoped capacity rejections (the
// black-hole vocabulary) and NEVER count request-shape context overflows
// (deterministic for the model — they indict the request, not the provider)
// or genuine faults (owned by the 5xx breakers).
func TestIsCapacityRejectStrike(t *testing.T) {
	cases := []struct {
		name   string
		errStr string
		want   bool
	}{
		// Node-scoped capacity rejects: COUNT. These are the incident strings —
		// a pair emitting them repeatedly with zero accepts is a black hole.
		{"active token budget", "token_budget_exhausted: request exceeds active token budget", true},
		{"requires-but-available", "token_budget_exhausted: request requires 115635 tokens but only 90000 available", true},
		{"kv headroom", "token_budget_exhausted: insufficient global KV cache headroom", true},
		{"queue full", "token_budget_exhausted: request queue full", true},
		{"server busy", "server busy", true},
		{"draining", "provider draining for update", true},
		{"cold not-loaded miss", "model 'gemma-4-26b-8bit' is not loaded on this provider", true},
		// "batch token budget" is deliberately INCLUDED (misreported-budget
		// pathology rejects normal prompts with exactly this string).
		{"batch token budget", "token_budget_exhausted: request exceeds batch token budget", true},

		// Request-shape context overflows: NEVER count (identical fleet-wide;
		// striking them would cool healthy providers on oversized-prompt bursts).
		{"exceeds model context window", "token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)", false},
		{"context length exceeded", "context length exceeded", false},
		{"context window bare marker", "prompt too long for context window", false},

		// Genuine faults / non-capacity: NEVER count (the 5xx breakers own them).
		{"panic", "panic: index out of range", false},
		{"internal error", "internal error", false},
		{"bad-weights load fault", "model load failed: corrupt weights", false},
		{"opaque foundation error", "The operation couldn’t be completed. (ProviderCore.InferenceError error 1.)", false},
		{"cancel", "request cancelled", false},
		{"empty", "", false},
		// A 404-shaped "model not found" (unknown model id) is a request-shape
		// error, NOT the cold "not loaded" capacity miss — never a strike.
		{"unknown model not found", "model not found", false},
		{"unknown model in registry", "model \"nope\" not found in registry", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsCapacityRejectStrike(tc.errStr); got != tc.want {
				t.Fatalf("isCapacityRejectStrike(%q) = %v, want %v", tc.errStr, got, tc.want)
			}
		})
	}
}
