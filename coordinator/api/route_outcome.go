package api

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) updateInferenceRouteOutcome(requestID string, attempt int, outcome *store.InferenceRouteOutcome) {
	if s == nil || s.store == nil || requestID == "" || outcome == nil {
		return
	}
	s.submitTelemetry("updateInferenceRoute", func() {
		_ = s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome)
	})
}

func (s *Server) updateInferenceRouteOutcomeForPending(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	if pr == nil {
		return
	}
	if outcome != nil && outcome.FinalStatus != "" && !pr.MarkRouteOutcomeFinalized() {
		return
	}
	s.updateInferenceRouteOutcome(pr.RequestID, pr.Attempt, outcome)
}

func routeOutcome(status, class string, code int) *store.InferenceRouteOutcome {
	return &store.InferenceRouteOutcome{
		FinalStatus: status,
		ErrorCode:   code,
		ErrorClass:  class,
	}
}

func committedRouteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	out := &store.InferenceRouteOutcome{}
	applyPendingRouteTelemetry(out, pr)
	return out
}

func pendingRouteOutcome(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	out := routeOutcome(status, class, code)
	applyPendingRouteTelemetry(out, pr)
	return out
}

func providerFailedPendingRouteOutcome(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	out := pendingRouteOutcome(pr, status, class, code)
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
	return providerFailedPendingRouteOutcome(pr, "partial_success", class, msg.StatusCode)
}

func preResponseProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	class := "provider_error_before_response"
	if providerDisconnectedError(msg.Error, msg.StatusCode) {
		class = "provider_disconnect_before_response"
	}
	return providerFailedPendingRouteOutcome(pr, "error", class, msg.StatusCode)
}

func preCommitProviderErrorOutcome(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	class := "provider_error"
	if providerDisconnectedError(msg.Error, msg.StatusCode) {
		class = "provider_disconnect_pre_commit"
	}
	return providerFailedPendingRouteOutcome(pr, "error", class, msg.StatusCode)
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
		errorClass = "client_gone_after_commit_provider_completed"
	}
	out := &store.InferenceRouteOutcome{
		FinalStatus:      status,
		ErrorClass:       errorClass,
		PromptTokens:     usage.PromptTokens,
		CompletionTokens: usage.CompletionTokens,
		ReasoningTokens:  usage.ReasoningTokens,
		CostMicroUSD:     costMicroUSD,
	}
	applyPendingRouteTelemetry(out, pr)
	return out
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
