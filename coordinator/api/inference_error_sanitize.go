package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// sanitizeProviderInferenceError is the provider-frame confidentiality
// boundary. It returns a copy containing only closed-vocabulary strings and
// status/message values derived from mutually validated closed fields. In
// particular, msg.Error is never read: provider-authored prose can contain
// prompts, paths, URLs, tool arguments, or arbitrary byte-encoding schemes and
// must not influence control flow or leave this function.
//
// Missing/unknown failure codes are accepted for mixed-fleet wire compatibility
// but fail closed as generation_failure. The booleans let the caller emit
// cardinality-safe drift counters without retaining or tagging the bad values.
func sanitizeProviderInferenceError(msg *protocol.InferenceErrorMessage) (safe protocol.InferenceErrorMessage, invalidCode, invalidCause bool) {
	if msg == nil {
		return protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			FailureCode: protocol.FailureCodeGenerationFailure,
			Error:       safeInferenceFailureMessage(protocol.FailureCodeGenerationFailure),
			StatusCode:  http.StatusInternalServerError,
			ErrorReason: errorReasonProviderError,
		}, true, false
	}

	safe.Type = protocol.TypeInferenceError
	safe.RequestID = msg.RequestID
	safe.AttemptUsage = msg.AttemptUsage
	safe.FailureCode = msg.FailureCode
	legacyFrame := safe.FailureCode == ""
	if !safe.FailureCode.Valid() {
		if legacyFrame {
			safe.FailureCode = legacyInferenceFailureCode(msg.StatusCode, msg.ErrorReason, msg.TerminalCause)
		} else {
			safe.FailureCode = protocol.FailureCodeGenerationFailure
		}
		invalidCode = true
	}

	safe.TerminalCause, invalidCause = sanitizeProviderTerminalCause(msg.TerminalCause)
	suppliedReason := msg.ErrorReason
	// Older providers used a bare 429 to mean queue saturation. Preserve that
	// bounded distinction during rolling upgrades; typed capacity frames remain
	// reason-driven, so capacity_timeout continues to canonicalize to 503.
	if legacyFrame &&
		msg.StatusCode == http.StatusTooManyRequests &&
		msg.ErrorReason == "" &&
		msg.TerminalCause == "" {
		suppliedReason = errorReasonQueueFull
	}
	safe.ErrorReason = safeInferenceErrorReason(safe.FailureCode, suppliedReason)
	safe.StatusCode = safeInferenceFailureStatus(safe.FailureCode, safe.ErrorReason, safe.TerminalCause, msg.StatusCode)
	safe.Error = safeInferenceFailureMessage(safe.FailureCode)
	return safe, invalidCode, invalidCause
}

// legacyInferenceFailureCode keeps a rolling upgrade operational without ever
// consulting legacy Error prose. Only bounded status/reason/cause values may
// refine the fail-closed generation_failure default.
func legacyInferenceFailureCode(status int, reason, terminalCause string) protocol.InferenceFailureCode {
	normalizedReason := normalizeInferenceErrorReason(reason)
	switch terminalCause {
	case terminalCauseAdmissionTimeout:
		return protocol.FailureCodeCapacity
	case terminalCauseCancelled:
		return protocol.FailureCodeCancelled
	}
	if isJinjaTemplateErrorReason(normalizedReason) {
		return protocol.FailureCodeTemplateRender
	}
	switch normalizedReason {
	case errorReasonModelLoad:
		switch status {
		case http.StatusNotFound:
			return protocol.FailureCodeModelUnavailable
		case http.StatusServiceUnavailable:
			return protocol.FailureCodeCapacity
		default:
			return protocol.FailureCodeInternalFailure
		}
	case errorReasonCapacityTimeout,
		errorReasonQueueFull,
		errorReasonTokenBudgetExhaust,
		errorReasonRequestExceedsContext,
		errorReasonRequestExceedsNode,
		errorReasonRequestExceedsNodeBudget,
		errorReasonRequestExceedsBatchBudget,
		errorReasonCapacityBusy:
		return protocol.FailureCodeCapacity
	case errorReasonCancelled:
		return protocol.FailureCodeCancelled
	case errorReasonClientError:
		return protocol.FailureCodeInvalidRequest
	case errorReasonToolNoncompliance:
		return protocol.FailureCodeGenerationFailure
	}
	switch status {
	case http.StatusBadRequest:
		return protocol.FailureCodeInvalidRequest
	case http.StatusUnprocessableEntity:
		// A legacy bare 422 was also used for model-output validation faults.
		// Without a bounded reason, treating it as a client fault would erase
		// provider health signals and stop failover. Fail closed as generation.
		return protocol.FailureCodeGenerationFailure
	case http.StatusRequestEntityTooLarge:
		return protocol.FailureCodeMediaTooLarge
	case http.StatusUnsupportedMediaType:
		return protocol.FailureCodeUnsupportedMedia
	case http.StatusNotFound:
		return protocol.FailureCodeModelUnavailable
	case http.StatusTooManyRequests, http.StatusServiceUnavailable:
		return protocol.FailureCodeCapacity
	case 499:
		return protocol.FailureCodeCancelled
	default:
		return protocol.FailureCodeGenerationFailure
	}
}

// safeInferenceFailureMessage is the only provider-failure prose allowed to
// reach coordinator logs, durable outcomes, telemetry, and API clients.
func safeInferenceFailureMessage(code protocol.InferenceFailureCode) string {
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

// safeInferenceFailureStatus canonicalizes status from code/reason/cause. The
// only preserved supplied-status distinction is model_unavailable 404 versus
// 503; all other combinations remain code-derived.
func safeInferenceFailureStatus(code protocol.InferenceFailureCode, errorReason, terminalCause string, suppliedStatus int) int {
	switch terminalCause {
	case terminalCauseAdmissionTimeout:
		return http.StatusServiceUnavailable
	case terminalCauseSafetyDeadline, terminalCauseBackpressureTimeout:
		return http.StatusGatewayTimeout
	case terminalCauseCancelled:
		return 499
	}
	switch code {
	case protocol.FailureCodeInvalidRequest:
		if errorReason == errorReasonToolNoncompliance {
			return http.StatusUnprocessableEntity
		}
		return http.StatusBadRequest
	case protocol.FailureCodeInvalidMedia:
		return http.StatusBadRequest
	case protocol.FailureCodeMediaTooLarge:
		return http.StatusRequestEntityTooLarge
	case protocol.FailureCodeUnsupportedMedia:
		return http.StatusUnsupportedMediaType
	case protocol.FailureCodeTemplateRender:
		return http.StatusUnprocessableEntity
	case protocol.FailureCodeCapacity:
		if errorReason == errorReasonQueueFull {
			return http.StatusTooManyRequests
		}
		return http.StatusServiceUnavailable
	case protocol.FailureCodeModelUnavailable:
		if suppliedStatus == http.StatusNotFound {
			return http.StatusNotFound
		}
		return http.StatusServiceUnavailable
	case protocol.FailureCodeCancelled:
		return 499
	case protocol.FailureCodeEncryptionFailure:
		return http.StatusBadGateway
	case protocol.FailureCodeGenerationFailure:
		if errorReason == errorReasonToolNoncompliance {
			return http.StatusUnprocessableEntity
		}
		return http.StatusInternalServerError
	case protocol.FailureCodeInternalFailure:
		return http.StatusInternalServerError
	default:
		return http.StatusInternalServerError
	}
}

func sanitizeProviderTerminalCause(cause string) (string, bool) {
	if _, known := classifyTerminalCause(cause); known {
		return cause, false
	}
	return "", true
}

func safeInferenceErrorReason(code protocol.InferenceFailureCode, supplied string) string {
	reason := normalizeInferenceErrorReason(supplied)
	switch code {
	case protocol.FailureCodeInvalidRequest:
		if reason == errorReasonToolNoncompliance {
			return reason
		}
		return errorReasonClientError
	case protocol.FailureCodeInvalidMedia,
		protocol.FailureCodeMediaTooLarge,
		protocol.FailureCodeUnsupportedMedia:
		return errorReasonClientError
	case protocol.FailureCodeTemplateRender:
		if isJinjaTemplateErrorReason(reason) {
			return reason
		}
		return errorReasonJinjaTemplate
	case protocol.FailureCodeModelUnavailable:
		return errorReasonModelLoad
	case protocol.FailureCodeCapacity:
		switch reason {
		case errorReasonModelLoad:
			return reason
		case errorReasonCapacityTimeout,
			errorReasonQueueFull,
			errorReasonTokenBudgetExhaust,
			errorReasonRequestExceedsContext,
			errorReasonRequestExceedsNode,
			errorReasonRequestExceedsNodeBudget,
			errorReasonRequestExceedsBatchBudget,
			errorReasonCapacityBusy:
			return reason
		default:
			return errorReasonCapacityTimeout
		}
	case protocol.FailureCodeCancelled:
		return errorReasonCancelled
	case protocol.FailureCodeGenerationFailure:
		if reason == errorReasonToolNoncompliance {
			return reason
		}
		return errorReasonProviderError
	case protocol.FailureCodeInternalFailure:
		if reason == errorReasonModelLoad {
			return reason
		}
		return errorReasonProviderError
	default:
		return errorReasonProviderError
	}
}

// clientSafeInferenceErrorMessage also protects response helpers invoked with
// coordinator-synthetic or directly-constructed messages that did not traverse
// the provider read-loop sanitizer.
func clientSafeInferenceErrorMessage(msg protocol.InferenceErrorMessage) string {
	if msg.CoordinatorCause == protocol.CoordinatorCauseProviderDisconnected {
		return "provider disconnected"
	}
	if msg.FailureCode.Valid() {
		return safeInferenceFailureMessage(msg.FailureCode)
	}
	return safeInferenceFailureMessage(protocol.FailureCodeGenerationFailure)
}

// normalizeInferenceErrorForInternalUse hardens helpers that are also called by
// tests and coordinator-synthetic paths rather than only by provider read-loop
// delivery. It preserves the one non-wire coordinator cause and otherwise
// applies the same provider ingress boundary.
func normalizeInferenceErrorForInternalUse(msg protocol.InferenceErrorMessage) protocol.InferenceErrorMessage {
	if msg.CoordinatorCause == protocol.CoordinatorCauseProviderDisconnected {
		return protocol.InferenceErrorMessage{
			Type:             protocol.TypeInferenceError,
			RequestID:        msg.RequestID,
			Error:            "provider disconnected",
			StatusCode:       http.StatusBadGateway,
			ErrorReason:      errorReasonProviderError,
			CoordinatorCause: protocol.CoordinatorCauseProviderDisconnected,
			AttemptUsage:     msg.AttemptUsage,
		}
	}
	safe, _, _ := sanitizeProviderInferenceError(&msg)
	return safe
}
