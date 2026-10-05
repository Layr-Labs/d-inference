package inference_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPredictiveRefusalIsRequestLocalAndRequiresNewEvidence(t *testing.T) {
	excluded := map[string]struct{}{}
	forecast := firstcontent.NewForecast(estimate.NewContextCalibration(),

		func(id string) { excluded[id] = struct{}{} })
	var terminal retry.TerminalEvidence
	var current retry.AttemptFailure
	var decision firstcontent.RefusalDecision
	for _, id := range []string{"a", "a", "b"} {
		provider := &registry.Provider{ID: id}
		current = terminal.Observe(provider, "", protocol.InferenceErrorMessage{
			FailureCode: protocol.FailureCodeCapacity, ErrorReason: failure.ErrorReasonDeadlineUnreachable,
			StatusCode: http.StatusServiceUnavailable,
		}, 0, backend.NewLatch(nil))
		decision = forecast.Refused(provider)
	}
	pr := &registry.PendingRequest{}
	forecast.Configure(pr, "", 0, 0, false)
	if decision.Count != 2 || !pr.RequireFreshFeasible || pr.RequireFreshFeasibleAfter.IsZero() {
		t.Fatalf("refusals=%d pending=%+v", decision.Count, pr)
	}
	selected := retry.NewTerminalFailure(current.Message, backend.Slot{})
	_, sticky := terminal.Select(selected, false)
	traits := selected.RetryTraits(registry.RequestTraits{AvoidVersion: "broken-for-another-request"})
	if len(excluded) != 2 || traits.AvoidVersion != "" || sticky {
		t.Fatal("predictive refusal did not remain request-local")
	}
}
