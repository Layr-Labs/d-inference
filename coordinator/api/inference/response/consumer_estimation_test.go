package response

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestResolveReasoningTokens covers the precedence between the provider's
// tokenizer-accurate count and the legacy completion-tokens fallback.
func TestResolveReasoningTokens(t *testing.T) {
	cases := []struct {
		name      string
		usage     protocol.UsageInfo
		reasoning string
		want      uint64
	}{
		{
			name:      "accurate count preferred",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 42},
			reasoning: "thinking...",
			want:      42,
		},
		{
			name:      "fallback to completion tokens for legacy provider",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 0},
			reasoning: "thinking...",
			want:      100,
		},
		{
			name:      "no reasoning content yields zero",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 0},
			reasoning: "",
			want:      0,
		},
		{
			name:      "accurate count wins even without reasoning text",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 7},
			reasoning: "",
			want:      7,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveReasoningTokens(tc.usage, tc.reasoning); got != tc.want {
				t.Errorf("resolveReasoningTokens = %d, want %d", got, tc.want)
			}
		})
	}
}
