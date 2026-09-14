package api

import (
	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"strings"
	"time"
)

const metricInferenceError = "inference.error"

// errorClassClientError is the route-outcome error_class for a DETERMINISTIC
// provider-returned client-shape 4xx (invalid tool payload / role / response
// format / unsupported media). The request is malformed by shape — identical on
// every provider — so it is NOT a provider fault and NOT an admission mismatch.
const errorClassClientError = "client_error"

// errorClassDeadlineUnreachable keeps provider pre-content deadline refusals
// distinct from generic provider faults and generic transient capacity in route
// telemetry. The provider is healthy; only this attempt's remaining SLA failed.
const errorClassDeadlineUnreachable = attempt.ErrorReasonDeadlineUnreachable

// Final-status values persisted on inference_routes (store.InferenceRouteOutcome
// .FinalStatus). Centralized so status comparisons/constructions don't drift on a
// bare string literal.
const (
	finalStatusSuccess        = "success"
	finalStatusPartialSuccess = "partial_success"
	finalStatusError          = "error"
	finalStatusCancelled      = "cancelled"
	finalStatusTimeout        = "timeout"
)

func (s *Server) updateInferenceRouteOutcomeWithModel(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil {
		return
	}
	// Loud guard: a negative raw TTFT was clamped to 0 (see
	// applyPendingRouteTelemetry). Emitting here — the single store-submit funnel
	// every terminal/commit outcome flows through — makes any regression of the
	// retried-request shared-Timing bug visible instead of silent.
	if outcome.InvalidTTFT {
		s.emitInvalidTTFT(model, "negative")
	}
	if s.store == nil || requestID == "" {
		return
	}
	s.emitInferenceErrorMetric(model, outcome)
	s.emitAttemptOutcomeMetric(model, outcome)
	s.emitCommittedRequestOutcomeORView(model, outcome)
	s.emitTimingDecompositionMetric(model, outcome.FinalStatus, outcome)
	// Off the request path: the batching sink pipelines this update with its
	// neighbours after the group's route inserts (route_telemetry_submit.go).
	s.submitRouteOutcome(requestID, attempt, model, outcome)
}

func (s *Server) emitInferenceErrorMetric(model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil || outcome.ErrorReason == "" || outcome.FinalStatus == "" || outcome.FinalStatus == finalStatusSuccess {
		return
	}
	tags := []string{"reason:" + outcome.ErrorReason}
	if model != "" {
		tags = append(tags, "model:"+model)
	}
	s.ddIncr(metricInferenceError, tags)
}

func (s *Server) updateInferenceRouteOutcomeForPending(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	if pr == nil {
		return
	}
	terminal := outcome != nil && outcome.FinalStatus != ""
	if terminal {
		if !pr.MarkRouteOutcomeFinalized() {
			return
		}
		if ap := pr.Profile; ap != nil {
			ap.SetOutcome(outcome.FinalStatus, profileErrorReason(outcome), "", "", "")
			// Consumer-side synthetic terminals ARE the terminal half; a success
			// outcome is written at commit time and must wait for the provider's
			// terminal so the record carries settlement stamps and its profile.
			// A terminal already claimed by a provider frame is completed by
			// that frame once its provider outcome is written, so the record is
			// never built with an empty provider_outcome in between.
			if outcome.FinalStatus != finalStatusSuccess {
				ap.CompleteTerminalUnlessClaimed()
			}
		}
		// Consumer-side synthetic terminals (notably registry.Disconnect's
		// ErrorCh delivery, local timeout, and grace expiry) do not pass through a
		// provider terminal handler. Close their cache-selection denominator as
		// unreported; the per-attempt claim makes this idempotent with provider
		// complete/error races.
		if s != nil {
			s.emitCacheSelectionTerminal(pr, protocol.UsageInfo{}, false, false)
		}
	}
	s.updateInferenceRouteOutcomeWithModel(pr.RequestID, pr.Attempt, pr.Model, outcome)
}

func routeOutcome(status, class string, code int) *store.InferenceRouteOutcome {
	return routeOutcomeWithReason(status, class, code, "", "")
}

func routeOutcomeWithReason(status, class string, code int, providerReason, errorText string) *store.InferenceRouteOutcome {
	return &store.InferenceRouteOutcome{
		FinalStatus: status,
		ErrorCode:   code,
		ErrorClass:  class,
		ErrorReason: inferenceErrorReason(providerReason, status, class, code, errorText),
		// Terminal cancel/error/timeout rows deliver 0 tokens; force-persist that
		// 0 (instead of leaving completion_tokens NULL) so the incident-majority
		// 0-token cancels are visible. Success writes its real count separately
		// via completeRouteOutcome.
		CompletionTokensSet: terminalForcesCompletionTokens(status),
	}
}

// terminalForcesCompletionTokens reports whether a terminal final_status must
// persist completion_tokens even when it is 0. Cancel/error/timeout rows deliver
// zero tokens and must record 0 (not NULL) so the 0-token cancel population is
// queryable; partial_success and success are handled by their own count writers.
func terminalForcesCompletionTokens(status string) bool {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case finalStatusCancelled, finalStatusError, finalStatusTimeout:
		return true
	default:
		return false
	}
}

func committedRouteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	out := &store.InferenceRouteOutcome{}
	applyPendingRouteTelemetry(out, pr)
	return out
}

// profileErrorReason is the reason vocabulary request_profiles.error_reason
// carries: the routes row's specific closed error_class when one was recorded
// (queue_timeout, first_chunk_timeout, speculative_loser, …), falling back to
// the normalized error_reason. Every profile writer (this funnel, the
// provider terminal path, closeUndispatchedAttempt via dispatchErrorClass and
// the queue exits) therefore speaks the error_class vocabulary.
func profileErrorReason(outcome *store.InferenceRouteOutcome) string {
	if outcome == nil {
		return ""
	}
	if outcome.ErrorClass != "" {
		return outcome.ErrorClass
	}
	return outcome.ErrorReason
}

func pendingRouteOutcome(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	out := pendingRouteOutcomeWithReason(pr, status, class, code, "", "")
	return out
}

func pendingRouteOutcomeWithReason(pr *registry.PendingRequest, status, class string, code int, providerReason, errorText string) *store.InferenceRouteOutcome {
	out := routeOutcomeWithReason(status, class, code, providerReason, errorText)
	applyPendingRouteTelemetry(out, pr)
	return out
}

func providerFailedPendingRouteOutcome(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	out := providerFailedPendingRouteOutcomeWithReason(pr, status, class, code, "", "")
	return out
}

func providerFailedPendingRouteOutcomeWithReason(pr *registry.PendingRequest, status, class string, code int, providerReason, errorText string) *store.InferenceRouteOutcome {
	out := pendingRouteOutcomeWithReason(pr, status, class, code, providerReason, errorText)
	out.AdmittedButFailed = true
	return out
}

func providerDisconnectedError(msg protocol.InferenceErrorMessage) bool {
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
func applyAttemptUsage(out *store.InferenceRouteOutcome, usage *protocol.UsageInfo) {
	if out == nil || usage == nil {
		return
	}
	out.PromptTokens = usage.PromptTokens
	out.CompletionTokens = usage.CompletionTokens
	out.CompletionTokensSet = true
	out.ReasoningTokens = usage.ReasoningTokens
}

func postCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = normalizeInferenceErrorForInternalUse(msg)
	class := "provider_error_after_commit"
	if providerDisconnectedError(msg) {
		class = "provider_disconnect_after_commit"
	}
	out := providerFailedPendingRouteOutcomeWithReason(pr, finalStatusPartialSuccess, class, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
	applyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func preResponseProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = normalizeInferenceErrorForInternalUse(msg)
	class := "provider_error_before_response"
	if providerDisconnectedError(msg) {
		class = "provider_disconnect_before_response"
	}
	out := providerFailedPendingRouteOutcomeWithReason(pr, finalStatusError, class, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
	applyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func preCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = normalizeInferenceErrorForInternalUse(msg)
	if attempt.IsDeadlineUnreachableErrorReason(msg.ErrorReason) {
		out := pendingRouteOutcomeWithReason(
			pr, finalStatusError, errorClassDeadlineUnreachable,
			msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
		applyAttemptUsage(out, msg.AttemptUsage)
		return out
	}
	if isTerminalClientErrorCode(msg.StatusCode) || attempt.IsNonProviderFaultErrorReason(msg.ErrorReason) {
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
		out := pendingRouteOutcomeWithReason(pr, finalStatusError, errorClassClientError, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
		applyAttemptUsage(out, msg.AttemptUsage)
		return out
	}
	class := "provider_error"
	if providerDisconnectedError(msg) {
		class = "provider_disconnect_pre_commit"
	}
	out := providerFailedPendingRouteOutcomeWithReason(pr, finalStatusError, class, msg.StatusCode, msg.ErrorReason, response.ClientSafeInferenceErrorMessage(msg))
	applyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func postCommitProviderIncompleteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return providerFailedPendingRouteOutcome(pr, finalStatusPartialSuccess, "provider_incomplete_after_commit", 502)
}

func preResponseProviderIncompleteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return providerFailedPendingRouteOutcome(pr, finalStatusError, "provider_incomplete_before_response", 502)
}

func postCommitStreamTimeoutOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, finalStatusPartialSuccess, "stream_timeout_after_commit", 504)
}

func preResponseTimeoutOutcome(pr *registry.PendingRequest, class string) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, finalStatusTimeout, class, 504)
}

func noTerminalAfterCancelOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, finalStatusPartialSuccess, "no_terminal_after_cancel", 504)
}

func speculativeLoserOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, finalStatusCancelled, "speculative_loser", 0)
}

func clientGoneBeforeResponseOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, finalStatusCancelled, "client_gone_before_response", 0)
}

func completeRouteOutcome(pr *registry.PendingRequest, usage protocol.UsageInfo, costMicroUSD int64, consumerGone bool) *store.InferenceRouteOutcome {
	status := finalStatusSuccess
	errorClass := ""
	if consumerGone {
		status = finalStatusPartialSuccess
		errorClass = errorClassClientGoneAfterCommitCompleted
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
		out.ErrorReason = inferenceErrorReason("", status, errorClass, 0, "")
	}
	applyPendingRouteTelemetry(out, pr)
	return out
}

// inferenceErrorReason returns the durable, normalized enum persisted on
// inference_routes and used as the Datadog reason tag. Provider-supplied reasons
// take precedence, but are still whitelisted so raw provider text cannot leak
// into telemetry storage.
func inferenceErrorReason(providerReason, status, class string, code int, message string) string {
	if reason := attempt.NormalizeInferenceErrorReason(providerReason); reason != "" {
		return reason
	}
	if status == "" && class == "" && code == 0 && message == "" {
		return ""
	}
	if strings.EqualFold(strings.TrimSpace(status), finalStatusSuccess) {
		return ""
	}

	lowerStatus := strings.ToLower(strings.TrimSpace(status))
	lowerClass := strings.ToLower(strings.TrimSpace(class))
	lowerMessage := strings.ToLower(strings.TrimSpace(message))

	switch {
	case strings.Contains(lowerMessage, attempt.ErrorReasonTokenBudgetExhaust) || strings.Contains(lowerClass, attempt.ErrorReasonTokenBudgetExhaust):
		return attempt.ErrorReasonTokenBudgetExhaust
	case lowerClass == attempt.ErrorReasonQueueFull || strings.Contains(lowerMessage, "queue full"):
		return attempt.ErrorReasonQueueFull
	case lowerClass == "queue_timeout" || lowerClass == attempt.ErrorReasonCapacityTimeout || strings.Contains(lowerMessage, "queue timeout") || strings.Contains(lowerMessage, "timed out waiting for a free slot"):
		return attempt.ErrorReasonCapacityTimeout
	case lowerStatus == attempt.ErrorReasonCancelled || code == 499 || strings.Contains(lowerClass, "client_gone") || strings.Contains(lowerClass, "cancel") || strings.Contains(lowerMessage, "request cancelled"):
		return attempt.ErrorReasonCancelled
	case lowerClass == attempt.ErrorReasonClientError || strings.HasPrefix(lowerClass, attempt.ErrorReasonClientError):
		return attempt.ErrorReasonClientError
	case lowerClass == attempt.ErrorReasonProviderError || strings.HasPrefix(lowerClass, "provider_error") || strings.HasPrefix(lowerClass, "provider_disconnect") || strings.Contains(lowerClass, "provider_incomplete") || strings.Contains(lowerClass, "stream_timeout") || strings.Contains(lowerClass, "first_chunk_timeout") || strings.Contains(lowerClass, "accepted_timeout") || strings.Contains(lowerClass, "preamble_liveness_timeout") || strings.Contains(lowerMessage, "provider disconnected") || code >= http.StatusInternalServerError:
		return attempt.ErrorReasonProviderError
	default:
		return attempt.ErrorReasonUnknown
	}
}

func applyPendingRouteTelemetry(out *store.InferenceRouteOutcome, pr *registry.PendingRequest) {
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
	applyTimingDecomposition(out, t, firstChunk)
}
