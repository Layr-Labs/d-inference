package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// rewriteRawFinishReason corrects a provider-reported "stop" finish_reason to
// "length" on a raw chat.completion object when the authoritative token counts
// show generation consumed the entire max-tokens budget.
func rewriteRawFinishReason(obj map[string]any, usage protocol.UsageInfo, requestedMax int) {
	if !truncatedByMaxTokens(usage, requestedMax) {
		return
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		if choice, ok := rawChoice.(map[string]any); ok {
			if fr, _ := choice["finish_reason"].(string); fr == "stop" {
				choice["finish_reason"] = "length"
			}
		}
	}
}

// truncatedByMaxTokens reports whether generation consumed the entire
// max-tokens budget. requestedMax is the effective bound — the consumer's
// explicit max_tokens or the coordinator-injected default — so hitting it
// means the engine cut generation short.
func truncatedByMaxTokens(usage protocol.UsageInfo, requestedMax int) bool {
	return requestedMax > 0 && usage.CompletionTokens >= requestedMax
}

// effectiveFinishReason resolves the finish_reason for a reconstructed
// response. The provider engine reports "stop" unconditionally, so a
// truncation-aware reason is re-derived from the authoritative token counts.
func effectiveFinishReason(extracted string, hasToolCalls bool, usage protocol.UsageInfo, requestedMax int) string {
	if extracted != "" && extracted != "stop" {
		return extracted
	}
	if truncatedByMaxTokens(usage, requestedMax) {
		return "length"
	}
	if hasToolCalls {
		return "tool_calls"
	}
	return "stop"
}
