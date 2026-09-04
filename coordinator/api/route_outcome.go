package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const metricInferenceError = "inference.error"

const (
	errorReasonJinjaChannelTags          = "jinja_channel_tags"
	errorReasonJinjaNullBridge           = "jinja_null_bridge"
	errorReasonJinjaTemplate             = "jinja_template"
	errorReasonModelLoad                 = "model_load"
	errorReasonCapacityTimeout           = "capacity_timeout"
	errorReasonQueueFull                 = "queue_full"
	errorReasonTokenBudgetExhaust        = "token_budget_exhausted"
	errorReasonRequestExceedsContext     = "request_exceeds_context"
	errorReasonRequestExceedsNode        = "request_exceeds_node"
	errorReasonRequestExceedsNodeBudget  = "request_exceeds_node_budget"
	errorReasonRequestExceedsBatchBudget = "request_exceeds_batch_token_budget"
	errorReasonCapacityBusy              = "capacity_busy"
	errorReasonDeadlineUnreachable       = "deadline_unreachable"
	errorReasonCancelled                 = "cancelled"
	errorReasonProviderError             = "provider_error"
	errorReasonClientError               = "client_error"
	// errorReasonToolNoncompliance (E5): the provider's typed 422 for a model
	// that failed a forced tool_choice contract (did not emit the required
	// call / emitted one outside the allowed set / exceeded the deferred
	// content limit). Output-dependent — a re-sample can comply — so 422 stays
	// on the normal bounded-failover path, NEVER in the terminal client-error
	// stop set (see isTerminalClientErrorCode).
	errorReasonToolNoncompliance = "tool_noncompliance"
	// errorReasonDraining (R2): the provider's typed refusal because it is
	// draining ahead of a restart/update. Transient capacity for failover
	// (another provider serves) that consumes NO transient-capacity retry,
	// derates NO gray-box state, and marks the provider draining
	// (registry.MarkDraining) so the next scan skips it.
	errorReasonDraining = protocol.InferenceErrorReasonDraining
	// errorReasonProviderRestart (R1): coordinator-internal marker stamped by
	// the registry on the pending-request flush of a GRACEFUL peer close
	// (restart/stop/update). Health-neutral through
	// isProviderHealthNeutralErrorReason; never accepted from the wire
	// (safeInferenceErrorReason does not emit it).
	errorReasonProviderRestart = protocol.InferenceErrorReasonProviderRestart
	errorReasonUnknown         = "unknown"
)

// errorClassClientError is the route-outcome error_class for a DETERMINISTIC
// provider-returned client-shape 4xx (invalid tool payload / role / response
// format / unsupported media). The request is malformed by shape — identical on
// every provider — so it is NOT a provider fault and NOT an admission mismatch.
const errorClassClientError = "client_error"

// errorClassDeadlineUnreachable keeps provider pre-content deadline refusals
// distinct from generic provider faults and generic transient capacity in route
// telemetry. The provider is healthy; only this attempt's remaining SLA failed.
const errorClassDeadlineUnreachable = errorReasonDeadlineUnreachable

// isJinjaTemplateErrorReason reports whether a provider-supplied error_reason
// identifies a DETERMINISTIC chat-template render failure (the DAR-329/341
// provider vocabulary). The template renders the request's tool schemas and
// message history the same way on every provider, so these are request-shape /
// model-capability faults: the dispatch ladder stops on the first occurrence
// (E4, see dispatch.go), the provider takes no reputation hit
// (handleInferenceError), and route rows record class client_error — while the
// jinja_* reason itself is PRESERVED on the row, so the
// inference.error{reason:jinja_template} series keeps measuring real render
// failures rather than being silenced by reclassification.
func isJinjaTemplateErrorReason(reason string) bool {
	switch normalizeInferenceErrorReason(reason) {
	case errorReasonJinjaChannelTags, errorReasonJinjaNullBridge, errorReasonJinjaTemplate:
		return true
	default:
		return false
	}
}

// isNonProviderFaultErrorReason reports whether a provider-supplied
// error_reason identifies a failure that is NOT the provider's fault:
//
//   - jinja_* template-render failures (isJinjaTemplateErrorReason, E4): the
//     REQUEST's tool schemas or message history cannot be rendered by the
//     model's chat template — deterministic for the request and identical on
//     every provider;
//   - tool_noncompliance (E5): the MODEL's sampled output broke a forced
//     tool_choice contract (did not emit the required call / emitted one
//     outside the allowed set / exceeded the deferred content limit) —
//     output-dependent, a re-sample can comply.
//
// This is the request/model-fault subset of the structured reasons exempted
// from reputation and provider-health tracking. The complete health-neutral
// vocabulary is isProviderHealthNeutralErrorReason, which also includes the
// request-clock-specific deadline_unreachable reason.
func isNonProviderFaultErrorReason(reason string) bool {
	return isJinjaTemplateErrorReason(reason) ||
		normalizeInferenceErrorReason(reason) == errorReasonToolNoncompliance
}

func isDeadlineUnreachableErrorReason(reason string) bool {
	return normalizeInferenceErrorReason(reason) == errorReasonDeadlineUnreachable
}

// isProviderHealthNeutralErrorReason is the shared gate for reputation and all
// provider-health/capacity trackers. Request/model faults remain neutral as
// before; deadline_unreachable joins them because it describes the coordinator
// supplied remaining SLA, not provider sickness or capacity dishonesty.
func isProviderHealthNeutralErrorReason(reason string) bool {
	return isNonProviderFaultErrorReason(reason) ||
		isDeadlineUnreachableErrorReason(reason) ||
		isProviderRestartErrorReason(reason)
}

// isProviderRestartErrorReason reports whether reason is the coordinator-
// internal provider_restart marker the registry stamps on the flushed
// terminals of a GRACEFUL peer close (registry.DisconnectWithReason). The
// requests fail over like any disconnect, but the terminal is health-neutral:
// no breaker/cooldown/ejection strike, no clear. An abrupt drop's flush
// carries no reason and keeps striking (the zombie discriminator).
func isProviderRestartErrorReason(reason string) bool {
	return normalizeInferenceErrorReason(reason) == errorReasonProviderRestart
}

// isDrainingErrorReason reports whether reason is the provider's typed
// draining refusal (R2): transient capacity that consumes no capacity retry
// and derates nothing; the provider is marked draining instead.
func isDrainingErrorReason(reason string) bool {
	return normalizeInferenceErrorReason(reason) == errorReasonDraining
}

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

var validInferenceErrorReasons = map[string]struct{}{
	errorReasonJinjaChannelTags:          {},
	errorReasonJinjaNullBridge:           {},
	errorReasonJinjaTemplate:             {},
	errorReasonModelLoad:                 {},
	errorReasonCapacityTimeout:           {},
	errorReasonQueueFull:                 {},
	errorReasonTokenBudgetExhaust:        {},
	errorReasonRequestExceedsContext:     {},
	errorReasonRequestExceedsNode:        {},
	errorReasonRequestExceedsNodeBudget:  {},
	errorReasonRequestExceedsBatchBudget: {},
	errorReasonCapacityBusy:              {},
	errorReasonDeadlineUnreachable:       {},
	errorReasonCancelled:                 {},
	errorReasonProviderError:             {},
	errorReasonClientError:               {},
	errorReasonToolNoncompliance:         {},
	errorReasonDraining:                  {},
	errorReasonProviderRestart:           {},
	errorReasonUnknown:                   {},
}

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

func dispatchFailedPendingRouteOutcome(pr *registry.PendingRequest, class string, code int) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, finalStatusError, class, code)
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
	out := providerFailedPendingRouteOutcomeWithReason(pr, finalStatusPartialSuccess, class, msg.StatusCode, msg.ErrorReason, clientSafeInferenceErrorMessage(msg))
	applyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func preResponseProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = normalizeInferenceErrorForInternalUse(msg)
	class := "provider_error_before_response"
	if providerDisconnectedError(msg) {
		class = "provider_disconnect_before_response"
	}
	out := providerFailedPendingRouteOutcomeWithReason(pr, finalStatusError, class, msg.StatusCode, msg.ErrorReason, clientSafeInferenceErrorMessage(msg))
	applyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func preCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	msg = normalizeInferenceErrorForInternalUse(msg)
	if isDeadlineUnreachableErrorReason(msg.ErrorReason) {
		out := pendingRouteOutcomeWithReason(
			pr, finalStatusError, errorClassDeadlineUnreachable,
			msg.StatusCode, msg.ErrorReason, clientSafeInferenceErrorMessage(msg))
		applyAttemptUsage(out, msg.AttemptUsage)
		return out
	}
	if isTerminalClientErrorCode(msg.StatusCode) || isNonProviderFaultErrorReason(msg.ErrorReason) {
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
		out := pendingRouteOutcomeWithReason(pr, finalStatusError, errorClassClientError, msg.StatusCode, msg.ErrorReason, clientSafeInferenceErrorMessage(msg))
		applyAttemptUsage(out, msg.AttemptUsage)
		return out
	}
	class := "provider_error"
	if providerDisconnectedError(msg) {
		class = "provider_disconnect_pre_commit"
	}
	out := providerFailedPendingRouteOutcomeWithReason(pr, finalStatusError, class, msg.StatusCode, msg.ErrorReason, clientSafeInferenceErrorMessage(msg))
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
	if reason := normalizeInferenceErrorReason(providerReason); reason != "" {
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
	case strings.Contains(lowerMessage, errorReasonTokenBudgetExhaust) || strings.Contains(lowerClass, errorReasonTokenBudgetExhaust):
		return errorReasonTokenBudgetExhaust
	case lowerClass == errorReasonQueueFull || strings.Contains(lowerMessage, "queue full"):
		return errorReasonQueueFull
	case lowerClass == "queue_timeout" || lowerClass == errorReasonCapacityTimeout || strings.Contains(lowerMessage, "queue timeout") || strings.Contains(lowerMessage, "timed out waiting for a free slot"):
		return errorReasonCapacityTimeout
	case lowerStatus == errorReasonCancelled || code == 499 || strings.Contains(lowerClass, "client_gone") || strings.Contains(lowerClass, "cancel") || strings.Contains(lowerMessage, "request cancelled"):
		return errorReasonCancelled
	case lowerClass == errorReasonClientError || strings.HasPrefix(lowerClass, errorReasonClientError):
		return errorReasonClientError
	case lowerClass == errorReasonProviderError || strings.HasPrefix(lowerClass, "provider_error") || strings.HasPrefix(lowerClass, "provider_disconnect") || strings.Contains(lowerClass, "provider_incomplete") || strings.Contains(lowerClass, "stream_timeout") || strings.Contains(lowerClass, "first_chunk_timeout") || strings.Contains(lowerClass, "accepted_timeout") || strings.Contains(lowerClass, "preamble_liveness_timeout") || strings.Contains(lowerMessage, "provider disconnected") || code >= http.StatusInternalServerError:
		return errorReasonProviderError
	default:
		return errorReasonUnknown
	}
}

func normalizeInferenceErrorReason(reason string) string {
	reason = strings.ToLower(strings.TrimSpace(reason))
	reason = strings.ReplaceAll(reason, "-", "_")
	if reason == "" {
		return ""
	}
	if _, ok := validInferenceErrorReasons[reason]; ok {
		return reason
	}
	return errorReasonUnknown
}

func applyPendingRouteTelemetry(out *store.InferenceRouteOutcome, pr *registry.PendingRequest) {
	if out == nil || pr == nil {
		return
	}
	out.UsedBackup = pr.UsedBackup
	out.BackupWon = pr.BackupWon
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
