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
	errorReasonJinjaChannelTags   = "jinja_channel_tags"
	errorReasonJinjaNullBridge    = "jinja_null_bridge"
	errorReasonJinjaTemplate      = "jinja_template"
	errorReasonModelLoad          = "model_load"
	errorReasonCapacityTimeout    = "capacity_timeout"
	errorReasonQueueFull          = "queue_full"
	errorReasonTokenBudgetExhaust = "token_budget_exhausted"
	errorReasonCancelled          = "cancelled"
	errorReasonProviderError      = "provider_error"
	errorReasonUnknown            = "unknown"
)

var validInferenceErrorReasons = map[string]struct{}{
	errorReasonJinjaChannelTags:   {},
	errorReasonJinjaNullBridge:    {},
	errorReasonJinjaTemplate:      {},
	errorReasonModelLoad:          {},
	errorReasonCapacityTimeout:    {},
	errorReasonQueueFull:          {},
	errorReasonTokenBudgetExhaust: {},
	errorReasonCancelled:          {},
	errorReasonProviderError:      {},
	errorReasonUnknown:            {},
}

func (s *Server) updateInferenceRouteOutcome(requestID string, attempt int, outcome *store.InferenceRouteOutcome) {
	s.updateInferenceRouteOutcomeWithModel(requestID, attempt, "", outcome)
}

func (s *Server) updateInferenceRouteOutcomeWithModel(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || s.store == nil || requestID == "" || outcome == nil {
		return
	}
	s.emitInferenceErrorMetric(model, outcome)
	s.submitTelemetry("updateInferenceRoute", func() {
		_ = s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome)
	})
}

func (s *Server) emitInferenceErrorMetric(model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil || outcome.ErrorReason == "" || outcome.FinalStatus == "" || outcome.FinalStatus == "success" {
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
	if outcome != nil && outcome.FinalStatus != "" && !pr.MarkRouteOutcomeFinalized() {
		return
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
	}
}

func committedRouteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	out := &store.InferenceRouteOutcome{}
	applyPendingRouteTelemetry(out, pr)
	return out
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
	return pendingRouteOutcome(pr, "error", class, code)
}

func providerDisconnectedError(errorText string, statusCode int) bool {
	return statusCode == 502 && strings.EqualFold(strings.TrimSpace(errorText), "provider disconnected")
}

func postCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	class := "provider_error_after_commit"
	if providerDisconnectedError(msg.Error, msg.StatusCode) {
		class = "provider_disconnect_after_commit"
	}
	return providerFailedPendingRouteOutcomeWithReason(pr, "partial_success", class, msg.StatusCode, msg.ErrorReason, msg.Error)
}

func preResponseProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	class := "provider_error_before_response"
	if providerDisconnectedError(msg.Error, msg.StatusCode) {
		class = "provider_disconnect_before_response"
	}
	return providerFailedPendingRouteOutcomeWithReason(pr, "error", class, msg.StatusCode, msg.ErrorReason, msg.Error)
}

func preCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	class := "provider_error"
	if providerDisconnectedError(msg.Error, msg.StatusCode) {
		class = "provider_disconnect_pre_commit"
	}
	return providerFailedPendingRouteOutcomeWithReason(pr, "error", class, msg.StatusCode, msg.ErrorReason, msg.Error)
}

func postCommitProviderIncompleteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return providerFailedPendingRouteOutcome(pr, "partial_success", "provider_incomplete_after_commit", 502)
}

func preResponseProviderIncompleteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return providerFailedPendingRouteOutcome(pr, "error", "provider_incomplete_before_response", 502)
}

func postCommitStreamTimeoutOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, "partial_success", "stream_timeout_after_commit", 504)
}

func preResponseTimeoutOutcome(pr *registry.PendingRequest, class string) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, "timeout", class, 504)
}

func noTerminalAfterCancelOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, "partial_success", "no_terminal_after_cancel", 504)
}

func speculativeLoserOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, "cancelled", "speculative_loser", 0)
}

func clientGoneBeforeResponseOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return pendingRouteOutcome(pr, "cancelled", "client_gone_before_response", 0)
}

func completeRouteOutcome(pr *registry.PendingRequest, usage protocol.UsageInfo, costMicroUSD int64, consumerGone bool) *store.InferenceRouteOutcome {
	status := "success"
	errorClass := ""
	if consumerGone {
		status = "partial_success"
		errorClass = errorClassClientGoneAfterCommitCompleted
	}
	out := &store.InferenceRouteOutcome{
		FinalStatus:      status,
		ErrorClass:       errorClass,
		PromptTokens:     usage.PromptTokens,
		CompletionTokens: usage.CompletionTokens,
		ReasoningTokens:  usage.ReasoningTokens,
		CostMicroUSD:     costMicroUSD,
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
	if strings.EqualFold(strings.TrimSpace(status), "success") {
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
	if !firstChunk.IsZero() && !t.DispatchedAt.IsZero() {
		ms := float64(firstChunk.Sub(t.DispatchedAt).Milliseconds())
		out.ActualTTFTMs = ms
		out.DispatchToFirstChunkMs = ms
	}
	if !t.ReceivedAt.IsZero() {
		out.TotalDurationMs = float64(time.Since(t.ReceivedAt).Milliseconds())
	}
	applyTimingDecomposition(out, t, firstChunk)
}
