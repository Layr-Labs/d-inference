// Package failure owns the closed provider-failure vocabulary and ingress sanitization.
package failure

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// SanitizeProviderError is the provider-frame confidentiality
// boundary. It returns a copy containing only closed-vocabulary strings and
// status/message values derived from mutually validated closed fields. In
// particular, msg.Error is never read: provider-authored prose can contain
// prompts, paths, URLs, tool arguments, or arbitrary byte-encoding schemes and
// must not influence control flow or leave this function.
//
// Every routable provider sets failure_code on every error frame, so a
// missing or unknown code is protocol drift: it fails closed as
// generation_failure. The booleans let the caller emit cardinality-safe drift
// counters without retaining or tagging the bad values.
func SanitizeProviderError(msg *protocol.InferenceErrorMessage) (safe protocol.InferenceErrorMessage, invalidCode, invalidCause bool) {
	if msg == nil {
		return protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			FailureCode: protocol.FailureCodeGenerationFailure,
			Error:       message(protocol.FailureCodeGenerationFailure),
			StatusCode:  http.StatusInternalServerError,
			ErrorReason: ErrorReasonProviderError,
		}, true, false
	}

	safe.Type = protocol.TypeInferenceError
	safe.RequestID = msg.RequestID
	safe.AttemptUsage = msg.AttemptUsage
	// The provider profile is carried through as an opaque byte copy, exactly
	// like AttemptUsage: it is NOT read here. It is length-checked on the read
	// loop and decoded/validated on the profile sink worker
	// (api/profiler_provider.go), after the terminal has been processed.
	if msg.Profile != nil {
		safe.Profile = append(json.RawMessage(nil), msg.Profile...)
	}
	safe.FailureCode = msg.FailureCode
	if !safe.FailureCode.Valid() {
		safe.FailureCode = protocol.FailureCodeGenerationFailure
		invalidCode = true
	}

	safe.TerminalCause, invalidCause = sanitizeProviderTerminalCause(msg.TerminalCause)
	suppliedReason := msg.ErrorReason
	// Enriched rejection (routing v2): the four additive fields are typed and
	// bounded, so they may cross the confidentiality boundary — RejectionReason
	// only from the closed CapacityRejectionReason vocabulary (unknown values
	// are treated as absent, matching the protocol contract), the numeric
	// fields clamped non-negative. A typed reason on a frame that carries no
	// structured error_reason is additionally mapped onto the EXISTING closed
	// error_reason vocabulary so classifyRejection's reason-first path (and
	// every breaker/cooldown funnel behind it) classifies the rejection without
	// a parallel classifier.
	if msg.RejectionReason.Valid() {
		safe.RejectionReason = msg.RejectionReason
		if suppliedReason == "" {
			suppliedReason = capacityRejectionErrorReason(msg.RejectionReason)
		}
	}
	if msg.AvailableTokenBudget != nil && *msg.AvailableTokenBudget >= 0 {
		// Pointer presence is the contract: an EXPLICIT zero means "the live
		// gate has no headroom RIGHT NOW" (transient) and must survive the
		// boundary, while nil keeps the stale-heartbeat fallback in play.
		// Copied into a fresh allocation so the safe frame never aliases the
		// raw provider message.
		v := *msg.AvailableTokenBudget
		safe.AvailableTokenBudget = &v
	}
	if msg.FeasibleAfterMS > 0 {
		safe.FeasibleAfterMS = msg.FeasibleAfterMS
	}
	safe.CapacitySeq = msg.CapacitySeq
	safe.ErrorReason = safeInferenceErrorReason(safe.FailureCode, suppliedReason)
	// Media-memory refusal describes preparation, not an engine terminal.
	// A typed engine terminal contradicts that exemption and must keep its
	// normal fault/cancellation semantics rather than bypass health tracking.
	if safe.ErrorReason == ErrorReasonMediaMemoryUnavailable && safe.TerminalCause != "" {
		safe.ErrorReason = ErrorReasonProviderError
		safe.FailureCode = protocol.FailureCodeGenerationFailure
	}
	if safe.ErrorReason == ErrorReasonMediaMemoryUnavailable {
		// Media scratch admission is not a fresh observation of text/KV
		// headroom, even if a sender attached the generic enrichment fields.
		safe.RejectionReason = ""
		safe.AvailableTokenBudget = nil
		safe.FeasibleAfterMS = 0
		safe.CapacitySeq = 0
	}
	safe.StatusCode = safeInferenceFailureStatus(safe.FailureCode, safe.ErrorReason, safe.TerminalCause, msg.StatusCode)
	safe.Error = message(safe.FailureCode)
	return safe, invalidCode, invalidCause
}

// message is the only provider-failure prose allowed to
// reach coordinator logs, durable outcomes, telemetry, and API clients.
func message(code protocol.InferenceFailureCode) string {
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
	case TerminalCauseAdmissionTimeout:
		return http.StatusServiceUnavailable
	case TerminalCauseSafetyDeadline, TerminalCauseBackpressureTimeout:
		return http.StatusGatewayTimeout
	case TerminalCauseCancelled:
		return 499
	}
	switch code {
	case protocol.FailureCodeInvalidRequest:
		if errorReason == ErrorReasonToolNoncompliance {
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
		if errorReason == ErrorReasonQueueFull {
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
		if errorReason == ErrorReasonToolNoncompliance {
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
	if _, known := ClassifyTerminalCause(cause); known {
		return cause, false
	}
	return "", true
}

func safeInferenceErrorReason(code protocol.InferenceFailureCode, supplied string) string {
	reason := NormalizeReason(supplied)
	switch code {
	case protocol.FailureCodeInvalidRequest:
		if reason == ErrorReasonToolNoncompliance {
			return reason
		}
		return ErrorReasonClientError
	case protocol.FailureCodeInvalidMedia,
		protocol.FailureCodeMediaTooLarge,
		protocol.FailureCodeUnsupportedMedia:
		return ErrorReasonClientError
	case protocol.FailureCodeTemplateRender:
		if IsJinjaTemplateErrorReason(reason) {
			return reason
		}
		return ErrorReasonJinjaTemplate
	case protocol.FailureCodeModelUnavailable:
		return ErrorReasonModelLoad
	case protocol.FailureCodeCapacity:
		switch reason {
		case ErrorReasonModelLoad:
			return reason
		case ErrorReasonCapacityTimeout,
			ErrorReasonQueueFull,
			ErrorReasonTokenBudgetExhaust,
			ErrorReasonMediaMemoryUnavailable,
			ErrorReasonRequestExceedsContext,
			ErrorReasonRequestExceedsNode,
			ErrorReasonRequestExceedsNodeBudget,
			ErrorReasonRequestExceedsBatchBudget,
			ErrorReasonCapacityBusy,
			ErrorReasonDeadlineUnreachable,
			ErrorReasonDraining:
			return reason
		default:
			return ErrorReasonCapacityTimeout
		}
	case protocol.FailureCodeCancelled:
		return ErrorReasonCancelled
	case protocol.FailureCodeGenerationFailure:
		if reason == ErrorReasonToolNoncompliance {
			return reason
		}
		return ErrorReasonProviderError
	case protocol.FailureCodeInternalFailure:
		if reason == ErrorReasonModelLoad {
			return reason
		}
		return ErrorReasonProviderError
	default:
		return ErrorReasonProviderError
	}
}

// NonStreamingResponseLimitError is the fixed text of the coordinator-only
// response_limit terminal. It contains no provider-authored prose.
const NonStreamingResponseLimitError = "provider response exceeds non-streaming response limit"

// ClientSafeMessage also protects response helpers invoked with
// coordinator-synthetic or directly-constructed messages that did not traverse
// the provider read-loop sanitizer.
func ClientSafeMessage(msg protocol.InferenceErrorMessage) string {
	if msg.CoordinatorCause == protocol.CoordinatorCauseResponseLimit {
		return NonStreamingResponseLimitError
	}
	if msg.CoordinatorCause.IsProviderDisconnect() {
		return "provider disconnected"
	}
	if msg.FailureCode.Valid() {
		return message(msg.FailureCode)
	}
	return message(protocol.FailureCodeGenerationFailure)
}

// NormalizeInternalError hardens helpers that are also called by
// tests and coordinator-synthetic paths rather than only by provider read-loop
// delivery. It preserves non-wire coordinator causes and otherwise
// applies the same provider ingress boundary.
func NormalizeInternalError(msg protocol.InferenceErrorMessage) protocol.InferenceErrorMessage {
	if msg.CoordinatorCause == protocol.CoordinatorCauseResponseLimit {
		return protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: msg.RequestID,
			FailureCode: protocol.FailureCodeGenerationFailure, Error: NonStreamingResponseLimitError,
			StatusCode: http.StatusBadGateway, ErrorReason: ErrorReasonProviderError,
			CoordinatorCause: protocol.CoordinatorCauseResponseLimit}
	}

	if msg.CoordinatorCause.IsProviderDisconnect() {
		// The abrupt flush carries no reason and stays provider_error; the
		// graceful restart flush keeps its coordinator-internal
		// provider_restart marker (health-neutral through the reason funnel).
		reason := ErrorReasonProviderError
		if msg.CoordinatorCause == protocol.CoordinatorCauseProviderRestart {
			reason = errorReasonProviderRestart
		}
		return protocol.InferenceErrorMessage{
			Type:             protocol.TypeInferenceError,
			RequestID:        msg.RequestID,
			Error:            "provider disconnected",
			StatusCode:       http.StatusBadGateway,
			ErrorReason:      reason,
			CoordinatorCause: msg.CoordinatorCause,
			AttemptUsage:     msg.AttemptUsage,
		}
	}
	safe, _, _ := SanitizeProviderError(&msg)
	return safe
}

// capacityRejectionErrorReason maps the typed wire CapacityRejectionReason
// onto the coordinator's existing closed error_reason vocabulary — the exact
// values classifyRejection's reason-first path (P1) already trusts. This is a
// vocabulary translation, never a new classifier: deterministic-vs-transient
// stays decided in one place (inference_failure_class.go).
//
//   - token_budget: the node's live active-token budget cannot fit the
//     request → node-scoped, transient (a bigger/idler box may serve).
//   - kv_headroom / memory_cap: this node's memory pressure → node-scoped.
//   - slot_state: loading/reloading/draining/crashed slot → busy now.
//   - deadline: admissible eventually, not within the remaining clock →
//     the health-neutral deadline_unreachable refusal.
//   - template / capability: request-shape refusals with no capacity-class
//     mapping; empty keeps the legacy status/string heuristics authoritative.
func capacityRejectionErrorReason(r protocol.CapacityRejectionReason) string {
	switch r {
	case protocol.RejectionReasonTokenBudget:
		return ErrorReasonRequestExceedsNodeBudget
	case protocol.RejectionReasonKVHeadroom, protocol.RejectionReasonMemoryCap:
		return ErrorReasonRequestExceedsNode
	case protocol.RejectionReasonSlotState:
		return ErrorReasonCapacityBusy
	case protocol.RejectionReasonDeadline:
		return ErrorReasonDeadlineUnreachable
	}
	return ""
}
