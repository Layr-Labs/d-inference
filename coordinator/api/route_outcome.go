package api

import (
	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const metricInferenceError = "inference.error"

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
	if s == nil || outcome == nil || outcome.ErrorReason == "" || outcome.FinalStatus == "" || outcome.FinalStatus == attempt.FinalStatusSuccess {
		return
	}
	tags := []string{"reason:" + outcome.ErrorReason}
	if model != "" {
		tags = append(tags, "model:"+model)
	}
	s.ddIncr(metricInferenceError, tags)
}

func (s *Server) updateInferenceRouteOutcomeForPending(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	attempt.PublishPendingOutcome(pr, outcome, pendingOutcomeObserver{server: s})
}

type pendingOutcomeObserver struct{ server *Server }

func (o pendingOutcomeObserver) CacheTerminal(pr *registry.PendingRequest) {
	if o.server != nil {
		o.server.emitCacheSelectionTerminal(pr, protocol.UsageInfo{}, false, false)
	}
}

func (o pendingOutcomeObserver) RouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	o.server.updateInferenceRouteOutcomeWithModel(requestID, attempt, model, outcome)
}
