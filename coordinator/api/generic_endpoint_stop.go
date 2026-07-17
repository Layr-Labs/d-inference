package api

import "github.com/eigeninference/d-inference/coordinator/protocol"

func requestedMessagesStopSequences(parsed map[string]any) []string {
	raw, ok := parsed["stop_sequences"].([]any)
	if !ok || len(raw) == 0 {
		return nil
	}
	sequences := make([]string, 0, len(raw))
	for _, value := range raw {
		if sequence, ok := value.(string); ok {
			sequences = append(sequences, sequence)
		}
	}
	return sequences
}

func allowedMatchedStopSequence(requested []string, matched string) string {
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
