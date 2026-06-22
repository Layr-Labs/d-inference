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
	errorReasonClientError        = "client_error"
	errorReasonUnknown            = "unknown"
)

// errorClassClientError is the route-outcome error_class for a DETERMINISTIC
// provider-returned client-shape 4xx (invalid tool payload / role / response
// format / unsupported media). The request is malformed by shape — identical on
// every provider — so it is NOT a provider fault and NOT an admission mismatch.
const errorClassClientError = "client_error"

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
	errorReasonClientError:        {},
	errorReasonUnknown:            {},
}

func (s *Server) updateInferenceRouteOutcomeWithModel(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || s.store == nil || requestID == "" || outcome == nil {
		return
	}
	s.emitInferenceErrorMetric(model, outcome)
	s.emitCancelMetrics(model, outcome)
	s.submitTelemetry("updateInferenceRoute", func() {
		if err := s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome); err != nil && s.logger != nil {
			s.logger.Error("inference_routes outcome update failed",
				"request_id", requestID,
				"attempt", attempt,
				"model", model,
				"final_status", outcome.FinalStatus,
				"error_class", outcome.ErrorClass,
				"error_reason", outcome.ErrorReason,
				"error", err,
			)
		}
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
		FinalStatus:             status,
		ErrorCode:               code,
		ErrorClass:              class,
		ErrorReason:             inferenceErrorReason(providerReason, status, class, code, errorText),
		CancelPhase:             deriveCancelPhase(status, class),
		CancelSource:            deriveCancelSource(status, class, code),
		PartialSettlementStatus: deriveCancelSettlement(status, class),
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
	if isTerminalClientErrorCode(msg.StatusCode) {
		// Deterministic client-shape 4xx: the request body is malformed/unservable
		// by shape (fails identically on every provider), not a provider fault.
		// Record as client_error WITHOUT AdmittedButFailed so it never pollutes the
		// admission-mismatch gauge.
		return pendingRouteOutcomeWithReason(pr, "error", errorClassClientError, msg.StatusCode, msg.ErrorReason, msg.Error)
	}
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
		// Consumer disconnected after commit but the provider completed: a
		// settled cancellation (provider paid, consumer charged). Record the
		// delivered/settled counts and that a provider terminal arrived.
		out.CancelPhase = deriveCancelPhase(status, errorClass)
		out.CancelSource = deriveCancelSource(status, errorClass, 0)
		out.PartialSettlementStatus = deriveCancelSettlement(status, errorClass)
		out.SettledPartialTokens = usage.CompletionTokens
		out.SettledPartialMicroUSD = costMicroUSD
		out.ProviderTerminalReceived = true
		out.ProviderTerminalAtMs = time.Now().UnixMilli()
		// DAR-346: the provider settles the delivered-token floor into
		// usage.CompletionTokens on a mid-stream cancel (commit dc5a4136), so the
		// settled completion gives us an EXACT delivered-token count — prefer it
		// over the coordinator's content-frame estimate (set in
		// applyPendingRouteTelemetry, which only fills when this is still zero).
		if usage.CompletionTokens > 0 {
			out.EstimatedDeliveredTokens = usage.CompletionTokens
		}
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
	// DAR-346: cancel-signal timestamp. Stamped ONLY at the actual WS-cancel send
	// sites (cancelDispatch, the post-commit disconnect defer) so it measures real
	// provider cancel latency. It stays unset when no provider cancel was sent
	// (e.g. a queued request canceled before any provider was assigned), and is
	// never backfilled to the terminal/grace-expiry outcome-build time.
	if ts := pr.CancelSignalSentAtSafe(); !ts.IsZero() {
		out.CancelSignalSentAtMs = ts.UnixMilli()
	}
	// DAR-346: delivery measurement — what actually reached the client before a
	// cancel/terminal. Counts opaque ciphertext SSE frames only (never decrypted).
	if snap := pr.DeliverySnapshot(); snap.Chunks > 0 {
		out.ChunksSent = snap.Chunks
		out.BytesSent = snap.Bytes
		if out.EstimatedDeliveredTokens == 0 {
			// Best effort: content frames ≈ tokens. Phase 3 supplies the exact
			// provider-reported count when present.
			out.EstimatedDeliveredTokens = snap.Chunks
		}
		if !snap.LastChunkAt.IsZero() {
			out.LastChunkAtMs = snap.LastChunkAt.UnixMilli()
		}
		idleGapMs := snap.MaxIdleGapMs
		// For an after-first-token cancel the decisive gap is usually the silence
		// AFTER the last delivered chunk (stream stalled, then the client closed) —
		// no later chunk records it, so fold in the trailing gap. Bound it at the
		// cancel-signal time (≈ client close), NOT time.Now(): this can run from the
		// terminal/grace path up to 30s after the close, and counting that
		// settlement wait would misclassify a quick user abort as stream_idle.
		if out.CancelPhase == cancelPhaseAfterFirstToken && !snap.LastChunkAt.IsZero() {
			if cancelAt := pr.CancelSignalSentAtSafe(); !cancelAt.IsZero() {
				if trailing := float64(cancelAt.Sub(snap.LastChunkAt).Milliseconds()); trailing > idleGapMs {
					idleGapMs = trailing
				}
			}
		}
		if idleGapMs > 0 {
			out.MaxIdleGapMs = idleGapMs
		}
		// Refine a generic client-close into a stream-idle cancel when a measured
		// no-progress gap preceded the close (provider stalled mid-stream).
		out.CancelSource = refineCancelSourceForIdle(out.CancelSource, out.CancelPhase, idleGapMs)
	}
	if pr.Timing == nil {
		return
	}
	t := pr.Timing
	firstChunk := pr.FirstChunkAtSafe()
	if !firstChunk.IsZero() {
		out.FirstChunkAtMs = firstChunk.UnixMilli()
	}
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
