package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPredictiveRaceRefusalsRequireFreshEvidence(t *testing.T) {
	d, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
	excluded := make(map[string]struct{})
	forecast := firstcontent.NewForecast(estimate.NewContextCalibration(), func(id string) { excluded[id] = struct{}{} })
	var refusal firstcontent.RefusalDecision
	race := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, func(provider *registry.Provider) {
		refusal = forecast.Refused(provider)
	})
	primaryPR.ErrorCh <- deadlineUnreachableMessage()
	backupPR.ErrorCh <- deadlineUnreachableMessage()
	result := race.Run(d.r.Context(),
		attempt.RaceAttempt{Provider: primary, Pending: primaryPR, RequestID: primaryPR.RequestID},
		attempt.RaceAttempt{Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID})
	if got := result.Outcome; got != attempt.Retry {
		t.Fatalf("race outcome=%v, want retry", got)
	}
	next := &registry.PendingRequest{}
	forecast.Configure(next, d.config.Model, 0, d.config.Deadline, false)
	if refusal.Count != 2 || !next.RequireFreshFeasible || next.RequireFreshFeasibleAfter.IsZero() {
		t.Fatalf("two refusing racers did not require fresh evidence: refusals=%d pending=%+v", refusal.Count, next)
	}
	for _, provider := range []*registry.Provider{primary, backup} {
		if _, wasExcluded := excluded[provider.ID]; !wasExcluded {
			t.Fatalf("refusing racer %q was not excluded", provider.ID)
		}
		// Error observation through another race path cannot spend a second
		// refusal on the same provider or move the evidence cutoff again.
		race.RecordLoser(provider, deadlineUnreachableMessage())
	}
	if refusal.Count != 2 || !refusal.FreshAfter.Equal(next.RequireFreshFeasibleAfter) {
		t.Fatal("duplicate loser observation counted another refusal")
	}
	failure := retry.NewTerminalFailure(result.Failure.Message, backend.Slot{})
	_, sticky := d.evidence.Select(failure, false)
	traits := failure.RetryTraits(registry.RequestTraits{AvoidVersion: *result.FailedVersion})
	if sticky || result.Terminal.UnservableReason != "" || result.Terminal.ClientStatusCode != 0 || traits.AvoidVersion != "" {
		t.Fatal("predictive race refusal became a sticky fault or version penalty")
	}
}
