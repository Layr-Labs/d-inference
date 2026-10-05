package inference_test

import (
	"net/http"
	"testing"
	"time"

	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// This fixture composes the same production wait, commit, timeout and speculative
// operations. Its observations are their returned values, not owner internals.
type contentWaitFixture struct {
	s                     *serverFixture
	r                     *http.Request
	provider              *registry.Provider
	pr                    *registry.PendingRequest
	timing                *registry.RequestTiming
	deadline              time.Duration
	speculativeAt         time.Duration
	hedgeAdvance          <-chan time.Time
	held                  []string
	content               attempt.Content
	failure               retry.AttemptFailure
	result                attempt.FirstWaitResult
	speculative           *inference.Speculative
	exclusions            providerdispatch.Exclusions
	forecast              *firstcontent.Forecast
	body                  []byte
	estimatedPromptTokens int
	speculativeResult     inference.SpeculativeResult
	preambleLiveness      bool
}

func newContentWaitFixture(t *testing.T, receivedAgo, deadline time.Duration) (*contentWaitFixture, *registry.PendingRequest) {
	s, provider, pr, r := waitDeadlineFixture(t, receivedAgo, deadline)
	exclusions := providerdispatch.NewExclusions()
	return &contentWaitFixture{
		s: s, r: r, provider: provider, pr: pr, timing: pr.Timing,
		deadline: deadline, speculativeAt: deadline / 2,
		speculative: s.NewSpeculative(s.NewDispatcher().NewPlan(nil)), exclusions: exclusions,
		forecast: firstcontent.NewForecast(estimate.NewContextCalibration(), exclusions.Exclude),
	}, pr
}

func (f *contentWaitFixture) clock() firstcontent.Clock {
	return firstcontent.NewClock(firstcontent.TimingReceivedAt(f.timing), f.deadline, f.speculativeAt)
}

func (f *contentWaitFixture) commit(chunk string) {
	f.content = f.s.NewContentCommitter().Commit(nil, f.pr, len(f.held), chunk)
}

func (f *contentWaitFixture) commitReady(msg protocol.InferenceErrorMessage) bool {
	content := f.s.NewContentCommitter().Buffered(nil, f.pr, &f.held, msg)
	if content == nil {
		return false
	}
	f.content = *content
	return true
}

func (f *contentWaitFixture) timeout(phase attempt.TimeoutPhase, budget time.Duration) bool {
	result := f.s.NewWaitTimeout(attempt.TimeoutConfig{
		Model: f.pr.Model, Provider: f.provider, Pending: f.pr, RequestID: f.pr.RequestID, Attempt: 0,
	}).Run(f.r.Context(), phase, budget)
	if result.Claimed {
		f.failure = result.Failure
	}
	return result.Claimed
}

func (f *contentWaitFixture) cancel() {
	f.s.cancels.CancelDispatch(f.provider, f.pr, cancellation.CauseClientGonePre)
}

func (f *contentWaitFixture) firstConfig() attempt.FirstWaitConfig {
	return attempt.FirstWaitConfig{Pending: f.pr, Timing: f.timing, Deadline: f.deadline,
		SpeculativeAt: f.speculativeAt, HedgeAdvance: f.hedgeAdvance}
}

func (f *contentWaitFixture) firstDependencies() attempt.FirstWaitDependencies {
	return attempt.FirstWaitDependencies{
		Ingress: attempt.ProviderIngress{}, Commit: f.commit, CommitReady: f.commitReady,
		Refine: func(at time.Duration) { f.speculativeAt = at }, Speculate: f.speculate,
		Timeout:    func() bool { return f.timeout(attempt.FirstContentTimeout, f.deadline) },
		ClientGone: f.cancel,
	}
}

func (f *contentWaitFixture) firstWith(waiter *attempt.FirstWait) attempt.Outcome {
	f.result = waiter.Run(f.r.Context(), &f.held)
	return f.result.Outcome
}

func (f *contentWaitFixture) first() attempt.Outcome {
	return f.firstWith(attempt.NewFirstWait(f.firstDependencies(), f.firstConfig()))
}

func (f *contentWaitFixture) single() attempt.Outcome {
	waiter := attempt.NewSingleWait(attempt.SingleWaitDependencies{
		Commit: f.commit, CommitReady: f.commitReady,
		Timeout: func() bool { return f.timeout(attempt.NoBackupTimeout, f.deadline) }, ClientGone: f.cancel,
	}, f.pr, f.clock(), f.deadline-f.speculativeAt)
	f.result = waiter.Run(f.r.Context(), &f.held)
	return f.result.Outcome
}

func (f *contentWaitFixture) accepted() attempt.Outcome {
	waiter := attempt.NewAcceptedWait(attempt.AcceptedWaitDependencies{
		Commit: f.commit, CommitReady: f.commitReady,
		Timeout: func(budget time.Duration) bool {
			phase := attempt.AcceptedTimeout
			if f.preambleLiveness {
				phase = attempt.PreambleTimeout
			}
			return f.timeout(phase, budget)
		}, ClientGone: f.cancel,
	}, attempt.AcceptedWaitConfig{Pending: f.pr, Clock: f.clock(), Deadline: f.deadline, PreambleLiveness: f.preambleLiveness})
	return waiter.Run(f.r.Context(), &f.held)
}

func (f *contentWaitFixture) speculate() attempt.Outcome {
	f.speculativeResult = f.speculative.Run(inference.SpeculativeRequest{
		Dispatch: providerdispatch.Input{
			Request: f.r, Model: f.pr.Model, Timing: f.timing, Deadline: f.deadline,
			Exclusions: f.exclusions, Forecast: f.forecast,
			Body: f.body, EstimatedPromptTokens: f.estimatedPromptTokens,
		},
		Primary: f.provider, Pending: f.pr, RequestID: f.pr.RequestID, SpeculativeAt: f.speculativeAt, Failure: f.failure,
	}, inference.SpeculativeWaits{
		NoBackup: func(history *inference.PrimaryHistory) attempt.Outcome {
			if history != nil {
				f.failure = history.Failure
			}
			return f.single()
		},
		Accepted: f.accepted,
		Race:     f.race,
	})
	return f.speculativeResult.Outcome
}

func (f *contentWaitFixture) race(backup *registry.Provider, pending *registry.PendingRequest) attempt.Outcome {
	race := f.s.NewRace(attempt.RaceConfig{
		Model: f.pr.Model, Deadline: f.deadline, SpeculativeAt: f.speculativeAt, Clock: f.clock(),
	}, retry.New(retry.Config{Model: f.pr.Model, Observation: f.s.observation}), &retry.TerminalEvidence{}, f.s.NewBackendLatch(), func() {}, func(p *registry.Provider) { f.forecast.Refused(p) })
	result := race.Run(f.r.Context(), attempt.RaceAttempt{
		Provider: f.provider, Pending: f.pr, RequestID: f.pr.RequestID, HeldChunks: f.held,
	}, attempt.RaceAttempt{Provider: backup, Pending: pending, RequestID: pending.RequestID})
	f.provider, f.pr, f.held = result.Attempt.Provider, result.Attempt.Pending, result.Attempt.HeldChunks
	if result.Content != nil {
		f.content = *result.Content
	}
	if result.Failure != nil {
		f.failure = *result.Failure
	}
	if result.PreambleLiveness {
		f.preambleLiveness = true
	}
	if result.Outcome == attempt.Accepted && !result.PreambleLiveness {
		return f.accepted()
	}
	return result.Outcome
}
