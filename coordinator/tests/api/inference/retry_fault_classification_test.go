package inference_test

import (
	"net/http"
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	retry "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestGenuineFaultClassificationExcludesNeutralAndDeterministicFailures(t *testing.T) {
	tests := []struct {
		name string
		msg  protocol.InferenceErrorMessage
		want bool
	}{
		{"internal failure", genuineInternalFaultMessage(), true},
		{"generation failure", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeGenerationFailure,
		}, true},
		{"capacity refusal", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeCapacity,
		}, false},
		{"model unavailable", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeModelUnavailable,
		}, false},
		{"deterministic client failure", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeInvalidRequest,
		}, false},
		{"template render failure", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeTemplateRender,
		}, false},
		{"tool noncompliance", protocol.InferenceErrorMessage{
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeGenerationFailure,
			ErrorReason: failure.ErrorReasonToolNoncompliance,
		}, false},
		{"deadline unreachable", deadlineUnreachableMessage(), false},
		{"admission timeout", protocol.InferenceErrorMessage{
			StatusCode:    http.StatusServiceUnavailable,
			FailureCode:   protocol.FailureCodeCapacity,
			TerminalCause: failure.TerminalCauseAdmissionTimeout,
		}, false},
		{"neutral safety deadline", protocol.InferenceErrorMessage{
			StatusCode:    http.StatusGatewayTimeout,
			FailureCode:   protocol.FailureCodeGenerationFailure,
			TerminalCause: failure.TerminalCauseSafetyDeadline,
		}, false},
		{"typed watchdog fault", protocol.InferenceErrorMessage{
			StatusCode:    http.StatusInternalServerError,
			FailureCode:   protocol.FailureCodeGenerationFailure,
			TerminalCause: failure.TerminalCauseWatchdog,
		}, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			msg := failure.NormalizeInternalError(tc.msg)
			if got := retry.IsGenuinePreContentFault(msg, 0, 0); got != tc.want {
				t.Fatalf("isGenuinePreContentFault() = %v, want %v; msg=%+v", got, tc.want, msg)
			}
		})
	}
}
