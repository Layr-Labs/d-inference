package responsepolicy

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// truncatedByMaxTokens reports whether generation consumed the entire
// max-tokens budget. requestedMax is the effective bound — the consumer's
// explicit max_tokens or the coordinator-injected default — so hitting it
// means the engine cut generation short.
func TruncatedByMaxTokens(usage protocol.UsageInfo, requestedMax int) bool {
	return requestedMax > 0 && usage.CompletionTokens >= requestedMax
}

// effectiveFinishReason resolves the finish_reason for a reconstructed
// response. The provider engine reports "stop" unconditionally, so a
// truncation-aware reason is re-derived from the authoritative token counts.
func EffectiveFinishReason(extracted string, hasToolCalls bool, usage protocol.UsageInfo, requestedMax int) string {
	if extracted != "" && extracted != "stop" {
		return extracted
	}
	if TruncatedByMaxTokens(usage, requestedMax) {
		return "length"
	}
	if hasToolCalls {
		return "tool_calls"
	}
	return "stop"
}

// resolveReasoningTokens returns the reasoning-token count to report.
// It prefers the provider's tokenizer-accurate count
// (UsageInfo.ReasoningTokens) and falls back to the coarse "all
// completion tokens" estimate only for older providers that emit
// reasoning content without a count — so a reasoning response never
// reports zero reasoning tokens, while up-to-date providers report the
// real split.
func ResolveReasoningTokens(usage protocol.UsageInfo, reasoning string) uint64 {
	if usage.ReasoningTokens > 0 {
		return uint64(usage.ReasoningTokens)
	}
	if reasoning != "" {
		return uint64(usage.CompletionTokens)
	}
	return 0
}
