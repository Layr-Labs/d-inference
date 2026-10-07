package inference_test

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func genuineInternalFaultMessage() protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		RequestID: "fault-request", Error: "backend exploded",
		StatusCode: http.StatusInternalServerError, FailureCode: protocol.FailureCodeInternalFailure,
	}
}

func deadlineUnreachableMessage() protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		RequestID: "deadline-request", Error: "remaining deadline cannot be met",
		StatusCode: http.StatusServiceUnavailable, FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: failure.ErrorReasonDeadlineUnreachable,
	}
}
