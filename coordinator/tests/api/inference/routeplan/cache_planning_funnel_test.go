package routeplan_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
)

// Every planning decision reason the planner can emit, with the terminal
// reason of a request that was then served without a plan.
func TestEveryPlanningDecisionHasOneFunnelTerminal(t *testing.T) {
	cases := map[routeplan.CachePlanningDecisionReason]cachefunnel.Reason{
		routeplan.CachePlanningOff:                     cachefunnel.NotEligible,
		routeplan.CachePlanningIneligible:              cachefunnel.NotEligible,
		routeplan.CachePlanningLoweringUnsupported:     cachefunnel.NotEligible,
		routeplan.CachePlanningColdOnly:                cachefunnel.NotEligible,
		routeplan.CachePlanningDependenciesUnavailable: cachefunnel.PlannerUnavailable,
		routeplan.CachePlanningArtifactMissing:         cachefunnel.PlannerUnavailable,
		routeplan.CachePlanningArtifactPending:         cachefunnel.PlannerUnavailable,
		routeplan.CachePlanningArtifactFailed:          cachefunnel.PlannerUnavailable,
		routeplan.CachePlanningArtifactInvalid:         cachefunnel.PlannerUnavailable,
		routeplan.CachePlanningPreloadNotReady:         cachefunnel.PlannerUnavailable,
		routeplan.CachePlanningSampledOut:              cachefunnel.SampledOut,
		routeplan.CachePlanningThrottled:               cachefunnel.RateLimited,
		routeplan.CachePlanningSidecarError:            cachefunnel.PlanFailed,
		routeplan.CachePlanningInvalidPlan:             cachefunnel.PlanFailed,
		routeplan.CachePlanningNoBoundaries:            cachefunnel.PlanEmpty,
		// An unnamed outcome is not guessed into a bucket.
		routeplan.CachePlanningUnknownOutcome: cachefunnel.PlanningUnobserved,
		// "Planned" without a plan on the dispatched body is not a planned request.
		routeplan.CachePlanningPlanned: cachefunnel.PlanningUnobserved,
	}
	for decision, want := range cases {
		t.Run(string(decision), func(t *testing.T) {
			if routeplan.BoundedCachePlanningReason(decision) != string(decision) {
				t.Fatalf("%q is not a planning decision the planner emits", decision)
			}
			ledger := cachefunnel.NewLedger(nil)
			request := ledger.Enter()
			request.NotePlanning(routeplan.FunnelPlanning(decision), cachefunnel.Tokens{})
			request.NoteAttemptDispatched(cachefunnel.Attempt{})
			request.NoteAttemptCompleted(cachefunnel.Attempt{}, cachefunnel.Completion{})
			request.Close(false)

			status := ledger.Snapshot()
			for _, totals := range status.Reasons {
				expected := uint64(0)
				if totals.Reason == want.String() {
					expected = 1
				}
				if totals.Requests != expected {
					t.Fatalf("decision %q: reason %q counts %d requests, want %d", decision, totals.Reason, totals.Requests, expected)
				}
			}
		})
	}
}
