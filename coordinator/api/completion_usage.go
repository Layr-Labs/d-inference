package api

import "github.com/eigeninference/d-inference/coordinator/protocol"

func validCompletionUsage(usage protocol.UsageInfo) bool {
	return usage.PromptTokens >= 0 &&
		usage.CompletionTokens >= 0 &&
		usage.ReasoningTokens >= 0 &&
		usage.ReasoningTokens <= usage.CompletionTokens
}

func invalidCompletionUsageError(requestID string) *protocol.InferenceErrorMessage {
	return &protocol.InferenceErrorMessage{
		Type:          protocol.TypeInferenceError,
		RequestID:     requestID,
		Error:         "provider reported invalid token usage",
		StatusCode:    500,
		FailureCode:   protocol.FailureCodeGenerationFailure,
		TerminalCause: terminalCauseEngineError,
	}
}
