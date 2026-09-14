package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// injectReasoningDetailIntoRawUsage splices
// completion_tokens_details.reasoning_tokens into a passthrough
// chat.completion object when the provider reported an accurate
// reasoning-token count (UsageInfo.ReasoningTokens) and the raw usage
// object didn't already carry the detail. It never overrides a value the
// provider already supplied, and is a no-op when there is no reasoning
// count or no usage object.
func injectReasoningDetailIntoRawUsage(obj map[string]any, usage protocol.UsageInfo) {
	if usage.ReasoningTokens <= 0 {
		return
	}
	usageObj, ok := obj["usage"].(map[string]any)
	if !ok {
		return
	}
	details, _ := usageObj["completion_tokens_details"].(map[string]any)
	if details == nil {
		details = map[string]any{}
	}
	if _, exists := details["reasoning_tokens"]; exists {
		return
	}
	details["reasoning_tokens"] = usage.ReasoningTokens
	usageObj["completion_tokens_details"] = details
	obj["usage"] = usageObj
}

// resolveReasoningTokens returns the reasoning-token count to report.
// It prefers the provider's tokenizer-accurate count
// (UsageInfo.ReasoningTokens) and falls back to the coarse "all
// completion tokens" estimate only for older providers that emit
// reasoning content without a count — so a reasoning response never
// reports zero reasoning tokens, while up-to-date providers report the
// real split.
func resolveReasoningTokens(usage protocol.UsageInfo, reasoning string) uint64 {
	if usage.ReasoningTokens > 0 {
		return uint64(usage.ReasoningTokens)
	}
	if reasoning != "" {
		return uint64(usage.CompletionTokens)
	}
	return 0
}
