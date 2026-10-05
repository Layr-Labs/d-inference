package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/rollout"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestPolicyDeadlinePredicatesHonorPassedClock pins the walk-clock contract:
// the predicates evaluate deadlines against the supplied instant, while the
// public no-arg forms retain wall-clock evaluation for non-walk callers.
func TestPolicyDeadlinePredicatesHonorPassedClock(t *testing.T) {
	reg := production.New(testLogger())
	future := time.Now().Add(time.Hour)

	reg.SetCodeAttestationPolicy(true, future)
	if reg.CodeAttestationEnforced() {
		t.Fatal("code attestation must not be enforced before the deadline (wall clock)")
	}
	if rollout.CodeAttestationRequired(true, future, future.Add(-time.Second)) {
		t.Fatal("At variant: before the deadline must not enforce")
	}
	if !rollout.CodeAttestationRequired(true, future, future) {
		t.Fatal("At variant: at the deadline must enforce")
	}

	reg.SetReleasePolicyEnforcement(true)
	reg.SetReleasePolicyEnforceAfter(future)
	if reg.ReleasePolicyEnforced() {
		t.Fatal("release policy must not be enforced before enforce-after (wall clock)")
	}
	if rollout.ReleaseEvidenceRequired(true, future, future.Add(-time.Second)) {
		t.Fatal("At variant: before enforce-after must not enforce")
	}
	if !rollout.ReleaseEvidenceRequired(true, future, future.Add(time.Second)) {
		t.Fatal("At variant: after enforce-after must enforce")
	}
}

// TestPrivateTextGateThreadsWalkClock pins that the routing chokepoint
// consults the deadlines at the clock it is handed: an un-attested provider
// is admitted before the APNs deadline and derouted after it.
func TestPrivateTextGateThreadsWalkClock(t *testing.T) {
	var planner *production.ReservationPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
	})
	const model = "clock-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 100)
	deadline := time.Now().Add(time.Hour)
	reg.SetCodeAttestationPolicy(true, deadline)
	p.Mu().Lock()
	if p.CodeAttested {
		p.Mu().Unlock()
		t.Fatal("precondition: provider un-attested")
	}
	// Keep the challenge fresh at both walk clocks so only the APNs deadline flips.
	p.LastChallengeVerified = deadline
	p.Mu().Unlock()
	eligibility := planner.PrepareEligibility()
	defer eligibility.Close()
	if !eligibility.PrivateText(p.ID, deadline.Add(-time.Minute)) {
		t.Fatal("before the deadline the un-attested provider must pass (grace)")
	}
	if eligibility.PrivateText(p.ID, deadline.Add(time.Minute)) {
		t.Fatal("after the deadline the un-attested provider must be derouted")
	}
	if !eligibility.Build(p.ID, model, production.TrustHardware, deadline.Add(-time.Minute), false, false) {
		t.Fatal("liveness gate must pass with a pre-deadline walk clock")
	}
	if eligibility.Build(p.ID, model, production.TrustHardware, deadline.Add(time.Minute), false, false) {
		t.Fatal("liveness gate must fail with a post-deadline walk clock")
	}
}
