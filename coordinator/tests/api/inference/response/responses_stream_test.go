package response_test

import (
	"testing"

	responsepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/responsepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestEffectiveFinishReasonTruncatedToolCalls(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 100}
	if got := responsepolicy.EffectiveFinishReason("stop", true, usage, 100); got != "length" {
		t.Errorf("truncated tool-call response finish_reason = %q, want length", got)
	}
	usage.CompletionTokens = 10
	if got := responsepolicy.EffectiveFinishReason("stop", true, usage, 100); got != "tool_calls" {
		t.Errorf("untruncated tool-call response finish_reason = %q, want tool_calls", got)
	}
}
