package attempt

import (
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// errorClassClientError is the route-outcome error_class for a DETERMINISTIC
// provider-returned client-shape 4xx (invalid tool payload / role / response
// format / unsupported media). The request is malformed by shape — identical on
// every provider — so it is NOT a provider fault and NOT an admission mismatch.
const ErrorClassClientError = "client_error"

// errorClassDeadlineUnreachable keeps provider pre-content deadline refusals
// distinct from generic provider faults and generic transient capacity in route
// telemetry. The provider is healthy; only this attempt's remaining SLA failed.
const ErrorClassDeadlineUnreachable = ErrorReasonDeadlineUnreachable

// Final-status values persisted on inference_routes (store.InferenceRouteOutcome
// .FinalStatus). Centralized so status comparisons/constructions don't drift on a
// bare string literal.
const (
	FinalStatusSuccess        = "success"
	FinalStatusPartialSuccess = "partial_success"
	FinalStatusError          = "error"
	FinalStatusCancelled      = "cancelled"
	FinalStatusTimeout        = "timeout"
)

func RouteOutcome(status, class string, code int) *store.InferenceRouteOutcome {
	return RouteOutcomeWithReason(status, class, code, "", "")
}

func RouteOutcomeWithReason(status, class string, code int, providerReason, errorText string) *store.InferenceRouteOutcome {
	return &store.InferenceRouteOutcome{
		FinalStatus: status,
		ErrorCode:   code,
		ErrorClass:  class,
		ErrorReason: InferenceErrorReason(providerReason, status, class, code, errorText),
		// Terminal cancel/error/timeout rows deliver 0 tokens; force-persist that
		// 0 (instead of leaving completion_tokens NULL) so the incident-majority
		// 0-token cancels are visible. Success writes its real count separately
		// via completeRouteOutcome.
		CompletionTokensSet: TerminalForcesCompletionTokens(status),
	}
}

// terminalForcesCompletionTokens reports whether a terminal final_status must
// persist completion_tokens even when it is 0. Cancel/error/timeout rows deliver
// zero tokens and must record 0 (not NULL) so the 0-token cancel population is
// queryable; partial_success and success are handled by their own count writers.
func TerminalForcesCompletionTokens(status string) bool {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case FinalStatusCancelled, FinalStatusError, FinalStatusTimeout:
		return true
	default:
		return false
	}
}

func CommittedRouteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	out := &store.InferenceRouteOutcome{}
	ApplyPendingRouteTelemetry(out, pr)
	return out
}

// profileErrorReason is the reason vocabulary request_profiles.error_reason
// carries: the routes row's specific closed error_class when one was recorded
// (queue_timeout, first_chunk_timeout, speculative_loser, …), falling back to
// the normalized error_reason. Every profile writer (this funnel, the
// provider terminal path, closeUndispatchedAttempt via dispatchErrorClass and
// the queue exits) therefore speaks the error_class vocabulary.
func ProfileErrorReason(outcome *store.InferenceRouteOutcome) string {
	if outcome == nil {
		return ""
	}
	if outcome.ErrorClass != "" {
		return outcome.ErrorClass
	}
	return outcome.ErrorReason
}

func PendingRouteOutcome(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	out := PendingRouteOutcomeWithReason(pr, status, class, code, "", "")
	return out
}

func PendingRouteOutcomeWithReason(pr *registry.PendingRequest, status, class string, code int, providerReason, errorText string) *store.InferenceRouteOutcome {
	out := RouteOutcomeWithReason(status, class, code, providerReason, errorText)
	ApplyPendingRouteTelemetry(out, pr)
	return out
}

func ProviderFailedPendingRouteOutcome(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	out := ProviderFailedPendingRouteOutcomeWithReason(pr, status, class, code, "", "")
	return out
}

func ProviderFailedPendingRouteOutcomeWithReason(pr *registry.PendingRequest, status, class string, code int, providerReason, errorText string) *store.InferenceRouteOutcome {
	out := PendingRouteOutcomeWithReason(pr, status, class, code, providerReason, errorText)
	out.AdmittedButFailed = true
	return out
}

func ProviderDisconnectedError(msg protocol.InferenceErrorMessage) bool {
	return msg.CoordinatorCause.IsProviderDisconnect()
}

// applyAttemptUsage copies a typed error terminal's provider-reported partial
// usage (InferenceErrorMessage.AttemptUsage, new providers only) onto the
// route row for OBSERVABILITY. This is the fix for the deadline incident's
// "every strict route had null prompt_tokens / completion_tokens" finding: the
// engine reconciles partial usage at the terminal, and the route row now keeps
// it. CompletionTokensSet force-persists an authoritative 0 (vs NULL).
// Strictly telemetry: billing, refunds, reservations, provider earnings, and
// payouts never read these route fields on an error terminal, and this helper
// deliberately never touches CostMicroUSD.
func ApplyAttemptUsage(out *store.InferenceRouteOutcome, usage *protocol.UsageInfo) {
	if out == nil || usage == nil {
		return
	}
	out.PromptTokens = usage.PromptTokens
	out.CompletionTokens = usage.CompletionTokens
	out.CompletionTokensSet = true
	out.ReasoningTokens = usage.ReasoningTokens
}

func PostCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = NormalizeInferenceErrorForInternalUse(msg)
	class := "provider_error_after_commit"
	if ProviderDisconnectedError(msg) {
		class = "provider_disconnect_after_commit"
	}
	out := ProviderFailedPendingRouteOutcomeWithReason(pr, FinalStatusPartialSuccess, class, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
	ApplyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func PreResponseProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = NormalizeInferenceErrorForInternalUse(msg)
	class := "provider_error_before_response"
	if ProviderDisconnectedError(msg) {
		class = "provider_disconnect_before_response"
	}
	out := ProviderFailedPendingRouteOutcomeWithReason(pr, FinalStatusError, class, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
	ApplyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func PreCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = NormalizeInferenceErrorForInternalUse(msg)
	if IsDeadlineUnreachableErrorReason(msg.ErrorReason) {
		out := PendingRouteOutcomeWithReason(
			pr, FinalStatusError, ErrorClassDeadlineUnreachable,
			msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
		ApplyAttemptUsage(out, msg.AttemptUsage)
		return out
	}
	if IsTerminalClientErrorCode(msg.StatusCode) || IsNonProviderFaultErrorReason(msg.ErrorReason) {
		// Deterministic non-provider fault: a 4xx status the provider maps for
		// malformed bodies, OR a structured non-provider-fault reason — jinja_*
		// template-render failures (arrive as provider 500s but are
		// request-shape faults, identical fleet-wide) and tool_noncompliance
		// (model-output-dependent 422s; the provider executed faithfully).
		// Record as client_error WITHOUT AdmittedButFailed so neither pollutes
		// the provider-fault or admission-mismatch telemetry, keyed on the SAME
		// vocabulary as the reputation and breaker exemptions
		// (isNonProviderFaultErrorReason) so the lists cannot drift.
		// msg.ErrorReason is threaded through so rows keep their reason.
		out := PendingRouteOutcomeWithReason(pr, FinalStatusError, ErrorClassClientError, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
		ApplyAttemptUsage(out, msg.AttemptUsage)
		return out
	}
	class := "provider_error"
	if ProviderDisconnectedError(msg) {
		class = "provider_disconnect_pre_commit"
	}
	out := ProviderFailedPendingRouteOutcomeWithReason(pr, FinalStatusError, class, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
	ApplyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func PostCommitProviderIncompleteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return ProviderFailedPendingRouteOutcome(pr, FinalStatusPartialSuccess, "provider_incomplete_after_commit", 502)
}

func PreResponseProviderIncompleteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return ProviderFailedPendingRouteOutcome(pr, FinalStatusError, "provider_incomplete_before_response", 502)
}

func PostCommitStreamTimeoutOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return PendingRouteOutcome(pr, FinalStatusPartialSuccess, "stream_timeout_after_commit", 504)
}

func PreResponseTimeoutOutcome(pr *registry.PendingRequest, class string) *store.InferenceRouteOutcome {
	return PendingRouteOutcome(pr, FinalStatusTimeout, class, 504)
}

func NoTerminalAfterCancelOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return PendingRouteOutcome(pr, FinalStatusPartialSuccess, "no_terminal_after_cancel", 504)
}

func SpeculativeLoserOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return PendingRouteOutcome(pr, FinalStatusCancelled, "speculative_loser", 0)
}

func ClientGoneBeforeResponseOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return PendingRouteOutcome(pr, FinalStatusCancelled, "client_gone_before_response", 0)
}

func CompleteRouteOutcome(pr *registry.PendingRequest, usage protocol.UsageInfo, costMicroUSD int64, consumerGone bool) *store.InferenceRouteOutcome {
	status := FinalStatusSuccess
	errorClass := ""
	if consumerGone {
		status = FinalStatusPartialSuccess
		errorClass = ErrorClassClientGoneAfterCommitCompleted
	}
	out := &store.InferenceRouteOutcome{
		FinalStatus:      status,
		ErrorClass:       errorClass,
		PromptTokens:     usage.PromptTokens,
		CompletionTokens: usage.CompletionTokens,
		// Authoritative provider-reported count; persist it even when 0 so a
		// 0-token success records 0 rather than NULL.
		CompletionTokensSet: true,
		ReasoningTokens:     usage.ReasoningTokens,
		CostMicroUSD:        costMicroUSD,
	}
	if errorClass != "" {
		out.ErrorReason = InferenceErrorReason("", status, errorClass, 0, "")
	}
	ApplyPendingRouteTelemetry(out, pr)
	return out
}

// inferenceErrorReason returns the durable, normalized enum persisted on
// inference_routes and used as the Datadog reason tag. Provider-supplied reasons
// take precedence, but are still whitelisted so raw provider text cannot leak
// into telemetry storage.
func InferenceErrorReason(providerReason, status, class string, code int, message string) string {
	if reason := NormalizeInferenceErrorReason(providerReason); reason != "" {
		return reason
	}
	if status == "" && class == "" && code == 0 && message == "" {
		return ""
	}
	if strings.EqualFold(strings.TrimSpace(status), FinalStatusSuccess) {
		return ""
	}

	lowerStatus := strings.ToLower(strings.TrimSpace(status))
	lowerClass := strings.ToLower(strings.TrimSpace(class))
	lowerMessage := strings.ToLower(strings.TrimSpace(message))

	switch {
	case strings.Contains(lowerMessage, ErrorReasonTokenBudgetExhaust) || strings.Contains(lowerClass, ErrorReasonTokenBudgetExhaust):
		return ErrorReasonTokenBudgetExhaust
	case lowerClass == ErrorReasonQueueFull || strings.Contains(lowerMessage, "queue full"):
		return ErrorReasonQueueFull
	case lowerClass == "queue_timeout" || lowerClass == ErrorReasonCapacityTimeout || strings.Contains(lowerMessage, "queue timeout") || strings.Contains(lowerMessage, "timed out waiting for a free slot"):
		return ErrorReasonCapacityTimeout
	case lowerStatus == ErrorReasonCancelled || code == 499 || strings.Contains(lowerClass, "client_gone") || strings.Contains(lowerClass, "cancel") || strings.Contains(lowerMessage, "request cancelled"):
		return ErrorReasonCancelled
	case lowerClass == ErrorReasonClientError || strings.HasPrefix(lowerClass, ErrorReasonClientError):
		return ErrorReasonClientError
	case lowerClass == ErrorReasonProviderError || strings.HasPrefix(lowerClass, "provider_error") || strings.HasPrefix(lowerClass, "provider_disconnect") || strings.Contains(lowerClass, "provider_incomplete") || strings.Contains(lowerClass, "stream_timeout") || strings.Contains(lowerClass, "first_chunk_timeout") || strings.Contains(lowerClass, "accepted_timeout") || strings.Contains(lowerClass, "preamble_liveness_timeout") || strings.Contains(lowerMessage, "provider disconnected") || code >= http.StatusInternalServerError:
		return ErrorReasonProviderError
	default:
		return ErrorReasonUnknown
	}
}

func ApplyPendingRouteTelemetry(out *store.InferenceRouteOutcome, pr *registry.PendingRequest) {
	if out == nil || pr == nil {
		return
	}
	out.BackupWon = pr.BackupWon.Load()
	out.UsedBackup = pr.UsedBackup.Load()
	if pr.Timing == nil {
		return
	}
	t := pr.Timing
	firstChunk := pr.FirstChunkAtSafe()
	// actual_ttft_ms is time-to-first-DELIVERED-content (FirstContentAt) measured
	// against the COMMITTED attempt's DispatchedAt. FirstContentAt is stamped only
	// on the committed attempt and DispatchedAt is that same attempt's dispatch,
	// so the two cannot come from different attempts — eliminating the
	// retried-request shared-Timing bug (FirstChunkAt of an early attempt minus a
	// later attempt's overwritten DispatchedAt) that produced the -378s rows.
	// Held role-only / lifecycle preamble (FirstChunkAt) is deliberately NOT used
	// here, so a fast-preamble-then-stall provider cannot look responsive. A
	// non-committed terminal (cancel/error: no content) leaves FirstContentAt zero
	// => actual_ttft_ms 0 (correct: zero tokens delivered).
	firstContent := pr.FirstContentAtSafe()
	if !firstContent.IsZero() && !t.DispatchedAt.IsZero() {
		ms := float64(firstContent.Sub(t.DispatchedAt).Milliseconds())
		if ms < 0 {
			// Should be impossible (same attempt), but clamp + flag so any
			// regression is loud (routing.invalid_ttft) rather than a poison -ms row.
			out.InvalidTTFT = true
			ms = 0
		}
		out.ActualTTFTMs = ms
	}
	// dispatch_to_first_chunk_ms stays the held-preamble (first-byte) diagnostic.
	// Clamp negatives so a stale-pointer regression cannot write a -ms value here
	// either.
	if !firstChunk.IsZero() && !t.DispatchedAt.IsZero() {
		if ms := float64(firstChunk.Sub(t.DispatchedAt).Milliseconds()); ms >= 0 {
			out.DispatchToFirstChunkMs = ms
		}
	}
	if !t.ReceivedAt.IsZero() {
		out.TotalDurationMs = float64(time.Since(t.ReceivedAt).Milliseconds())
	}
	ApplyTimingDecomposition(out, t, firstChunk)
}
