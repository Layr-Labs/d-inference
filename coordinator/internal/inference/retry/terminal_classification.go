package retry

import (
	"net/http"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	rejection "github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func IsGenuinePreContentFault(
	msg protocol.InferenceErrorMessage,
	providerBudget int64,
	modelContext int,
) bool {
	if msg.StatusCode < http.StatusInternalServerError {
		return false
	}
	if failure.IsProviderHealthNeutralErrorReason(msg.ErrorReason) {
		return false
	}
	switch msg.FailureCode {
	case protocol.FailureCodeInvalidRequest,
		protocol.FailureCodeInvalidMedia,
		protocol.FailureCodeMediaTooLarge,
		protocol.FailureCodeUnsupportedMedia,
		protocol.FailureCodeTemplateRender,
		protocol.FailureCodeModelUnavailable,
		protocol.FailureCodeCapacity,
		protocol.FailureCodeCancelled:
		return false
	}
	switch class, _ := failure.ClassifyTerminalCause(msg.TerminalCause); class {
	case failure.CauseClassNeutral, failure.CauseClassCapacity:
		return false
	case failure.CauseClassFault:
		return true
	}
	return rejection.Classify(
		msg.ErrorReason, msg.Error, providerBudget, modelContext,
		msg.RejectionReason,
	) == rejection.NotCapacity
}

// classifyExhaustedStatus preserves provider-attempt telemetry while mapping a
// coordinator-synthesized pre-content timeout to the retryable status exposed to
// the caller. A typed provider 504 (safety deadline / backpressure timeout) is a
// real provider terminal and must remain 504; an untyped 504 is the dispatch
// loop's existing discriminator for its own first-content timeout.
func ClassifyExhaustedStatus(statusCode int, terminalCause string) (code int, reason string, reclassified bool) {
	if statusCode == http.StatusGatewayTimeout && !failure.IsTypedTimeout504Cause(terminalCause) {
		return http.StatusTooManyRequests, "first_chunk_timeout", true
	}
	return statusCode, "dispatch_exhausted", false
}
