package registry

import (
	"testing"
	"time"
)

// TestPolicyDeadlinePredicatesHonorPassedClock pins the walk-clock contract:
// the ...AtLocked variants evaluate the two rollout deadlines against the
// instant they are given (the walk's single captured now), while the no-arg
// forms keep reading the wall clock for non-walk callers.
func TestPolicyDeadlinePredicatesHonorPassedClock(t *testing.T) {
	reg := New(testLogger())
	future := time.Now().Add(time.Hour)
	reg.mu.Lock()
	defer reg.mu.Unlock()

	reg.codeAttestationConfigured = true
	reg.codeAttestationDeadline = future
	if reg.codeAttestationEnforcedLocked() {
		t.Fatal("code attestation must not be enforced before the deadline (wall clock)")
	}
	if reg.codeAttestationEnforcedAtLocked(future.Add(-time.Second)) {
		t.Fatal("At variant: before the deadline must not enforce")
	}
	if !reg.codeAttestationEnforcedAtLocked(future) {
		t.Fatal("At variant: at the deadline must enforce")
	}

	reg.releasePolicyEnforced = true
	reg.releasePolicyEnforceAfter = future
	if reg.releasePolicyEnforcedLocked() {
		t.Fatal("release policy must not be enforced before enforce-after (wall clock)")
	}
	if reg.releasePolicyEnforcedAtLocked(future.Add(-time.Second)) {
		t.Fatal("At variant: before enforce-after must not enforce")
	}
	if !reg.releasePolicyEnforcedAtLocked(future.Add(time.Second)) {
		t.Fatal("At variant: after enforce-after must enforce")
	}
}

// TestPrivateTextGateThreadsWalkClock pins that the routing chokepoint
// consults the deadlines at the clock it is handed: an un-attested provider
// is admitted for a walk clocked before the APNs deadline and derouted for a
// walk clocked after it, with no wall-clock read in between.
func TestPrivateTextGateThreadsWalkClock(t *testing.T) {
	reg := New(testLogger())
	const model = "clock-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 100)
	deadline := time.Now().Add(time.Hour)
	reg.mu.Lock()
	defer reg.mu.Unlock()
	reg.codeAttestationConfigured = true
	reg.codeAttestationDeadline = deadline
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.CodeAttested {
		t.Fatal("precondition: provider un-attested")
	}
	// Keep the challenge fresh at both walk clocks so the only gate that can
	// flip between them is the APNs deadline.
	p.LastChallengeVerified = deadline
	if !reg.providerSupportsPrivateTextAtLocked(p, deadline.Add(-time.Minute)) {
		t.Fatal("before the deadline the un-attested provider must pass (grace)")
	}
	if reg.providerSupportsPrivateTextAtLocked(p, deadline.Add(time.Minute)) {
		t.Fatal("after the deadline the un-attested provider must be derouted")
	}
	if !reg.providerLivenessGateLocked(p, TrustHardware, false, deadline.Add(-time.Minute)) {
		t.Fatal("liveness gate must pass with a pre-deadline walk clock")
	}
	if reg.providerLivenessGateLocked(p, TrustHardware, false, deadline.Add(time.Minute)) {
		t.Fatal("liveness gate must fail with a post-deadline walk clock")
	}
}
