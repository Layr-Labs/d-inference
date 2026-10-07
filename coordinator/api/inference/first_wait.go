package inference

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (d *dispatchState) firstWaitConfig() attempt.FirstWaitConfig {
	return attempt.FirstWaitConfig{
		Pending: d.pr, Timing: d.timing, Deadline: d.deadline,
		SpeculativeAt: d.speculativeAt, HedgeAdvance: d.hedgeAdvanceCh,
	}
}

func (d *dispatchState) firstWaitDependencies() attempt.FirstWaitDependencies {
	s, provider, pr := d.s, d.provider, d.pr
	timeout := d.newWaitTimeout()
	recovery := s.NewFirstWaitFailure(d.model, d.modelMaxContext, &d.terminalEvidence, d.backendLatch(), d.notePredictiveRefusal)
	return attempt.FirstWaitDependencies{
		Ingress: attempt.ProviderIngress{},
		Commit: func(chunk string) {
			d.commitFirstContent(pr, chunk)
			d.committed = true
		},
		CommitReady: func(msg protocol.InferenceErrorMessage) bool {
			return d.commitReadyFirstContent(pr, &d.heldChunks, msg)
		},
		Failure: func(msg protocol.InferenceErrorMessage, closed bool) {
			d.excludeProviders[provider.ID] = struct{}{}
			d.finishRace(recovery.Run(d.r.Context(), d.raceAttempt(), d.attempt, msg, closed))
		},
		Refine: func(at time.Duration) {
			d.speculativeAt = at
		},
		Speculate: d.runSpeculative,
		Timeout: func() bool {
			result := timeout.Run(d.r.Context(), attempt.FirstContentTimeout, d.deadline)
			if !result.Claimed {
				return false
			}
			d.excludeProviders[provider.ID] = struct{}{}
			d.setLastError(result.Failure.Message.Error, result.Failure.Message.StatusCode)
			d.provider, d.pr = nil, nil
			return true
		},
		ClientGone: func() {
			s.cancelDispatch(provider, pr, cancellation.CauseClientGonePre)
			d.refundReservation()
		},
	}
}

func (d *dispatchState) waitFirstChunk() dispatchOutcome {
	waiter := attempt.NewFirstWait(d.firstWaitDependencies(), d.firstWaitConfig())
	pr := d.pr
	captured := routingAttempt(d.provider, pr, pr.RequestID, pr.Attempt)
	d.preambleLiveness = false
	result := waiter.RunRecorded(d.r.Context(), &d.heldChunks, captured, d.s.NewRouteRecorder(), d.model, func(result attempt.FirstWaitResult) attempt.FirstWaitTerminal {
		end := attempt.FirstWaitTerminal{Current: routingAttempt(d.provider, d.pr, d.requestID, d.attempt)}
		switch result.Outcome {
		case outcomeCommitted:
			end.Build = d.successRoutingOutcomeFor
		case outcomeRetry:
			if d.lastErrCode == http.StatusGatewayTimeout && !failure.IsTypedTimeout504Cause(d.lastErrTerminalCause) {
				end.Build = func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
					return d.errorRoutingOutcomeFor(pr, "timeout", "first_chunk_timeout", d.lastErrCode)
				}
			} else {
				end.Build = d.providerFailedRoutingOutcomeFor
			}
		case outcomeClientGone:
			d.emitClientGone(phaseBeforeFirstToken)
			end.Build = func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
				return d.errorRoutingOutcomeFor(pr, "cancelled", "client_gone", 0)
			}
		}
		return end
	})
	if result.PreambleLiveness {
		d.preambleLiveness = true
	}
	if result.Outcome == attempt.Committed {
		d.committed = true
	}
	return result.Outcome
}
