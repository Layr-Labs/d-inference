package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func AllowedMatchedStopSequence(requested []string, matched string) string {
	if matched == "" {
		return ""
	}
	for _, sequence := range requested {
		if sequence == matched {
			return matched
		}
	}
	return ""
}

func messagesStopOutcome(
	reason string,
	usage protocol.UsageInfo,
	maxTokens int,
	matchedStopSequence string,
) (string, any) {
	// The provider's exact match is authoritative. The generic max-token
	// heuristic cannot distinguish a stop sequence completed by the final
	// allowed token, while the engine can and gives stop matching precedence.
	if matchedStopSequence != "" {
		return "stop_sequence", matchedStopSequence
	}
	switch genericFinishReason(reason, usage, maxTokens) {
	case "length":
		return "max_tokens", nil
	case "tool_calls":
		return "tool_use", nil
	}
	return "end_turn", nil
}
