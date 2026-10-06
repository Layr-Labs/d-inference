package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// NewRace binds speculative arbitration to the same owner's cancellation,
// content commit, attempt refunds and route accounting as ordinary dispatch.
func (s *Owner) NewRace(config attempt.RaceConfig, policy *retry.Controller, evidence *retry.TerminalEvidence, latch *backend.Latch, refund func(), refused func(*registry.Provider)) *attempt.Race {
	return attempt.NewRace(attempt.RaceDependencies{
		Cancel: s.cancelDispatch, CancelTerminal: s.cancelDispatchAfterTerminal,
		CancelTimeout: s.cancelDispatchForFirstContentTimeout, Refund: refund,
		FailedVersion: failedProviderVersion, PredictiveRefusal: refused,
		Committer: s.NewContentCommitter(), Effects: s.NewAttemptEffects(),
		Routes: s.NewRouteRecorder(), Observation: s.observation, Registry: s.registry,
		Retry: policy, Evidence: evidence, Backend: latch,
	}, config)
}

func (d *dispatchState) newRace() *attempt.Race {
	return d.s.NewRace(attempt.RaceConfig{
		Model: d.model, ModelContext: d.modelMaxContext,
		Deadline: d.deadline, SpeculativeAt: d.speculativeAt,
		Clock: d.firstContentClock(), Profile: d.profile,
		TerminalLatched: d.unservable || d.terminalClientError,
	}, d.retryController(), &d.terminalEvidence, d.backendLatch(), d.refundReservation, d.notePredictiveRefusal)
}

func (d *dispatchState) raceAttempt() attempt.RaceAttempt {
	return attempt.RaceAttempt{Provider: d.provider, Pending: d.pr, RequestID: d.requestID, HeldChunks: d.heldChunks}
}

func (d *dispatchState) finishRace(result attempt.RaceResult) dispatchOutcome {
	d.provider, d.pr, d.requestID = result.Attempt.Provider, result.Attempt.Pending, result.Attempt.RequestID
	d.heldChunks = result.Attempt.HeldChunks
	if result.Content != nil {
		d.firstChunk = result.Content.FirstChunk
		if result.Content.InitialError != nil {
			d.initialError = result.Content.InitialError
		}
	}
	if result.Failure != nil {
		msg := result.Failure.Message
		d.lastErr, d.lastErrCode, d.lastErrReason = msg.Error, msg.StatusCode, msg.ErrorReason
		d.lastErrProviderBudget = result.Failure.ProviderBudget
		d.lastErrRejectionReason, d.lastErrTerminalCause = msg.RejectionReason, msg.TerminalCause
		d.lastErrCoordinatorCause, d.lastErrAttemptUsage = msg.CoordinatorCause, msg.AttemptUsage
		d.lastErrFeasibleAfterMS = msg.FeasibleAfterMS
		d.lastFailureDeadline = failure.IsDeadlineUnreachableErrorReason(msg.ErrorReason)
	}
	if result.FailedVersion != nil {
		d.lastFailedVersion = *result.FailedVersion
	}
	for _, id := range result.ExcludedProviderIDs {
		d.excludeProviders[id] = struct{}{}
	}
	if result.Terminal != nil {
		d.applyRetryDecision(*result.Terminal)
	}
	if result.Outcome == attempt.Committed {
		d.committed = true
	}
	if result.PreambleLiveness {
		d.preambleLiveness = true
	}
	if result.Outcome == attempt.Accepted && !result.PreambleLiveness {
		// Empty completion still needs the original accepted wait's terminal
		// arbitration (including its 50ms close/error grace) before returning.
		return d.waitAccepted()
	}
	return result.Outcome
}
