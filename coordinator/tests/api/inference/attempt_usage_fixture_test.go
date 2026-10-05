package inference_test

import (
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func attemptUsageErrMsg(reqID string, usage *protocol.UsageInfo) protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		Type:          protocol.TypeInferenceError,
		RequestID:     reqID,
		Error:         "request exceeded safety deadline",
		StatusCode:    504,
		TerminalCause: failure.TerminalCauseSafetyDeadline,
		AttemptUsage:  usage,
		FailureCode:   protocol.FailureCodeGenerationFailure,
	}
}
