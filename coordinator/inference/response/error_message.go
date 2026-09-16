package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// safeInferenceFailureMessage is the only provider-failure prose allowed to
// reach coordinator logs, durable outcomes, telemetry, and API clients.
func SafeInferenceFailureMessage(code protocol.InferenceFailureCode) string {
	switch code {
	case protocol.FailureCodeInvalidRequest:
		return "invalid inference request"
	case protocol.FailureCodeInvalidMedia:
		return "invalid media input"
	case protocol.FailureCodeMediaTooLarge:
		return "media input exceeds size limit"
	case protocol.FailureCodeUnsupportedMedia:
		return "unsupported media input"
	case protocol.FailureCodeTemplateRender:
		return "model template could not render the request"
	case protocol.FailureCodeModelUnavailable:
		return "model not loaded"
	case protocol.FailureCodeCapacity:
		return "request rejected: provider capacity unavailable"
	case protocol.FailureCodeCancelled:
		return "request cancelled"
	case protocol.FailureCodeEncryptionFailure:
		return "encrypted inference transport failed"
	case protocol.FailureCodeInternalFailure:
		return "provider internal error"
	case protocol.FailureCodeGenerationFailure:
		fallthrough
	default:
		return "inference generation failed"
	}
}

// clientSafeInferenceErrorMessage also protects response helpers invoked with
// coordinator-synthetic or directly-constructed messages that did not traverse
// the provider read-loop sanitizer.
func ClientSafeInferenceErrorMessage(msg protocol.InferenceErrorMessage) string {
	if msg.CoordinatorCause.IsProviderDisconnect() {
		return "provider disconnected"
	}
	if msg.FailureCode.Valid() {
		return SafeInferenceFailureMessage(msg.FailureCode)
	}
	return SafeInferenceFailureMessage(protocol.FailureCodeGenerationFailure)
}
