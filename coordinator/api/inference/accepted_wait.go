package inference

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (d *dispatchState) acceptedWaitDependencies() attempt.AcceptedWaitDependencies {
	s, provider, pr := d.s, d.provider, d.pr
	base := d.firstWaitDependencies()
	timeout := d.newWaitTimeout()
	return attempt.AcceptedWaitDependencies{
		Ingress: base.Ingress, Commit: base.Commit, CommitReady: base.CommitReady, ClientGone: base.ClientGone,
		Failure: func(msg protocol.InferenceErrorMessage) {
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatchAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, msg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed after accepting request, retrying", "request_id", d.requestID,
				"provider_id", provider.ID, "attempt", d.attempt+1, "failure_code", msg.FailureCode)
			s.observation.EmitRequest(d.r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed after accepting request, retrying", map[string]any{
					"provider_id": provider.ID, "attempt": d.attempt + 1, "reason": "provider_error", "status_code": msg.StatusCode,
				})
			if s.observation.Metrics() != nil {
				s.observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "retry"})
			}
			d.noteDispatchRetry(provider, pr, msg.StatusCode, msg.Error, msg.ErrorReason, msg.TerminalCause, &d.heldChunks, msg.CoordinatorCause)
			d.provider, d.pr = nil, nil
		},
		Timeout: func(budget time.Duration) bool {
			phase := attempt.AcceptedTimeout
			if d.preambleLiveness {
				phase = attempt.PreambleTimeout
			}
			result := timeout.Run(d.r.Context(), phase, budget)
			if !result.Claimed {
				return false
			}
			d.excludeProviders[provider.ID] = struct{}{}
			d.setLastError(result.Failure.Message.Error, result.Failure.Message.StatusCode)
			d.provider, d.pr = nil, nil
			return true
		},
	}
}

func (d *dispatchState) waitAccepted() (outcome dispatchOutcome) {
	pr := d.pr
	captured := routingAttempt(d.provider, pr, pr.RequestID, pr.Attempt)
	defer func() {
		target := d.currentOrCapturedRoutingAttempt(captured)
		switch outcome {
		case outcomeCommitted:
			target.Record(d.s.NewRouteRecorder(), d.model, d.successRoutingOutcomeFor)
		case outcomeRetry:
			if d.lastErrCode == http.StatusGatewayTimeout && !failure.IsTypedTimeout504Cause(d.lastErrTerminalCause) {
				class := "accepted_timeout"
				if d.preambleLiveness {
					class = "preamble_liveness_timeout"
				}
				target.Record(d.s.NewRouteRecorder(), d.model, func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
					return d.errorRoutingOutcomeFor(pr, "timeout", class, d.lastErrCode)
				})
			} else {
				target.Record(d.s.NewRouteRecorder(), d.model, d.providerFailedRoutingOutcomeFor)
			}
		case outcomeClientGone:
			d.emitClientGone(phaseBeforeFirstToken)
			target.Record(d.s.NewRouteRecorder(), d.model, func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
				return d.errorRoutingOutcomeFor(pr, "cancelled", "client_gone", 0)
			})
		}
	}()
	waiter := attempt.NewAcceptedWait(d.acceptedWaitDependencies(), attempt.AcceptedWaitConfig{
		Pending: pr, Clock: d.firstContentClock(), Deadline: d.deadline, PreambleLiveness: d.preambleLiveness,
	})
	outcome = waiter.Run(d.r.Context(), &d.heldChunks)
	if outcome == outcomeCommitted {
		d.committed = true
	}
	return outcome
}
