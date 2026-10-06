package inference

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// FirstWaitFailure releases a failed active attempt while retaining its request
// identity for the wait's deferred terminal accounting. All effects use the
// same owner as dispatch and speculative arbitration.
type FirstWaitFailure struct {
	s            *Owner
	model        string
	modelContext int
	evidence     *retry.TerminalEvidence
	latch        *backend.Latch
	refused      func(*registry.Provider)
}

func (s *Owner) NewFirstWaitFailure(model string, modelContext int, evidence *retry.TerminalEvidence, latch *backend.Latch, refused func(*registry.Provider)) *FirstWaitFailure {
	return &FirstWaitFailure{s: s, model: model, modelContext: modelContext, evidence: evidence, latch: latch, refused: refused}
}

func (f *FirstWaitFailure) Run(ctx context.Context, current attempt.RaceAttempt, index int, msg protocol.InferenceErrorMessage, closed bool) attempt.RaceResult {
	s, provider, pr := f.s, current.Provider, current.Pending
	s.cancelDispatchAfterTerminal(provider, pr)
	evidence := f.evidence.Observe(provider, f.model, msg, f.modelContext, f.latch)
	if failure.IsDeadlineUnreachableErrorReason(evidence.Message.ErrorReason) {
		f.refused(provider)
	}
	version := failedProviderVersion(provider)
	if !closed {
		s.logger.Warn("provider failed, retrying", "request_id", current.RequestID,
			"provider_id", provider.ID, "attempt", index+1, "failure_code", msg.FailureCode)
		s.observation.EmitRequest(ctx, protocol.SeverityWarn, current.RequestID,
			"provider failed, retrying", map[string]any{
				"provider_id": provider.ID, "attempt": index + 1,
				"reason": "provider_error", "status_code": msg.StatusCode,
			})
		if s.observation.Metrics() != nil {
			s.observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "retry"})
		}
	}
	s.NewAttemptEffects().Retry(provider, pr, msg.StatusCode, msg.Error, msg.ErrorReason, msg.TerminalCause, &current.HeldChunks, msg.CoordinatorCause)
	return attempt.RaceResult{
		Outcome: attempt.Retry,
		Attempt: attempt.RaceAttempt{RequestID: current.RequestID, HeldChunks: current.HeldChunks},
		Failure: &evidence, FailedVersion: &version, ExcludedProviderIDs: []string{provider.ID},
	}
}
