package inference

import (
	"fmt"
	"net/http"
	"time"

	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) primaryClientGone(in PrimaryRequest, provider *registry.Provider) {
	d := in.Dispatch
	bucket := infermetrics.DeadlineUnknown
	if d.Timing != nil && !d.Timing.ReceivedAt.IsZero() && d.Deadline > 0 {
		bucket = infermetrics.DeadlineBucket(time.Since(d.Timing.ReceivedAt), d.Deadline)
	}
	s.emitClientGone(d.Model, d.EstimatedPromptTokens, provider, d.Profile, bucket, phaseBeforeFirstToken)
}

func (in PrimaryRequest) rejectionInfo(stage, reason string, status, retryAfterMS int, decision registry.RoutingDecision) rejection.Prepared {
	d := in.Dispatch
	return rejection.BuildDispatch(d.Request, rejection.DispatchMetadata{
		Model: d.Model, PublicModel: d.PublicModel, ConsumerKey: d.ConsumerKey, Stream: in.Stream,
		EstimatedPromptTokens: d.EstimatedPromptTokens, RequestedMaxTokens: d.RequestedMaxTokens,
		RequiresVision: d.RequiresVision, HasTools: d.Traits.HasTools,
		SelfRouteOnly: d.Scope.SelfRouteOnly, PreferOwner: d.Scope.PreferOwner,
		OverflowBodyBytes: in.History.Overflow.Bytes,
	}, stage, reason, status, retryAfterMS, &decision)
}

func (p *Primary) terminal(in PrimaryRequest, info rejection.Prepared, retryAfter int, errType, message, code string) {
	p.s.NewRejectionRecorder().PreContentTerminal(in.Writer, in.Dispatch.Request, info.Record,
		info.Servability, retryAfter, errType, message, code)
}

// RejectUnforecastable prevents a public request from spending its absolute
// deadline on a queue wait unsupported by any credible capacity-release time.
func (p *Primary) RejectUnforecastable(in PrimaryRequest, decision registry.RoutingDecision) bool {
	d := in.Dispatch
	if d.Deadline <= 0 || d.Scope.SelfRouteOnly || d.Scope.PreferOwner {
		return false
	}
	code, reason := http.StatusTooManyRequests, "machine_busy"
	errType, message := "rate_limit_exceeded", fmt.Sprintf("all providers for model %q are at capacity", d.PublicModel)
	if decision.CapacityRejections == 0 && decision.CandidateCount == 0 {
		code, reason = http.StatusServiceUnavailable, "no_provider"
		errType, message = "provider_error", fmt.Sprintf("no provider available for model %q", d.PublicModel)
	}
	p.s.registry.RecordWarmPoolCapacityReject(d.Model)
	p.s.triggerWarmPool()
	retryAfter := p.s.estimateRetryAfter(d.Model)
	in.Refund()
	p.terminal(in, in.rejectionInfo("dispatch", reason, code, retryAfter*1000, decision), retryAfter, errType, message, errType)
	return true
}
