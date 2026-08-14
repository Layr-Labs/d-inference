package protocol

// InferenceFailureCode is the closed, cross-language vocabulary for failures
// returned by a provider while handling an inference request. Provider-authored
// prose is deliberately not part of this contract: the coordinator maps these
// values to fixed messages before logging, persistence, telemetry, or client
// delivery.
type InferenceFailureCode string

// CoordinatorInferenceErrorCause marks coordinator-synthetic terminals. It is
// never decoded from or encoded onto the provider wire, so an untrusted provider
// cannot claim these control-plane-only conditions.
type CoordinatorInferenceErrorCause string

const CoordinatorCauseProviderDisconnected CoordinatorInferenceErrorCause = "provider_disconnected"

const (
	FailureCodeInvalidRequest    InferenceFailureCode = "invalid_request"
	FailureCodeInvalidMedia      InferenceFailureCode = "invalid_media"
	FailureCodeMediaTooLarge     InferenceFailureCode = "media_too_large"
	FailureCodeUnsupportedMedia  InferenceFailureCode = "unsupported_media"
	FailureCodeTemplateRender    InferenceFailureCode = "template_render"
	FailureCodeModelUnavailable  InferenceFailureCode = "model_unavailable"
	FailureCodeCapacity          InferenceFailureCode = "capacity"
	FailureCodeCancelled         InferenceFailureCode = "cancelled"
	FailureCodeEncryptionFailure InferenceFailureCode = "encryption_failure"
	FailureCodeGenerationFailure InferenceFailureCode = "generation_failure"
	FailureCodeInternalFailure   InferenceFailureCode = "internal_failure"
)

// Valid reports whether c belongs to the protocol's closed vocabulary.
func (c InferenceFailureCode) Valid() bool {
	switch c {
	case FailureCodeInvalidRequest,
		FailureCodeInvalidMedia,
		FailureCodeMediaTooLarge,
		FailureCodeUnsupportedMedia,
		FailureCodeTemplateRender,
		FailureCodeModelUnavailable,
		FailureCodeCapacity,
		FailureCodeCancelled,
		FailureCodeEncryptionFailure,
		FailureCodeGenerationFailure,
		FailureCodeInternalFailure:
		return true
	default:
		return false
	}
}
