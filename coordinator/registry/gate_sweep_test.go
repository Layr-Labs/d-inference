package registry

import (
	"testing"
	"time"
)

// Tests for the gate sweep (gate_sweep.go): the liveness rule and the idle
// grace, including a fresh gate's creation counting as activity.

// The sweep never drops a gate a connected session references, drops an
// identity-less session's gate at Disconnect, and drops a disconnected
// identity's gate only once it is idle AND past the idle grace.
func TestGateSweepLivenessRule(t *testing.T) {
	reg := New(testLogger())
	anon := makeSchedulerProvider(t, reg, "sess-anon", "m", 100)
	attested := attestSchedulerProvider(t, reg, "sess-att", "m", "SER-SWEEP", 100)
	reg.RecordProviderOutcome(attested.ID, false, 500, "internal error")

	reg.sweepGates(time.Now().Add(24 * time.Hour))
	if rawGateForKey(reg, anon.ID) == nil || rawGateForKey(reg, "serial:SER-SWEEP") == nil {
		t.Fatal("gates with a connected session must survive any sweep")
	}

	reg.Disconnect(anon.ID)
	if rawGateForKey(reg, anon.ID) != nil {
		t.Fatal("an identity-less session's gate must be dropped at Disconnect")
	}

	reg.Disconnect(attested.ID)
	if rawGateForKey(reg, "serial:SER-SWEEP") == nil {
		t.Fatal("a stable identity's gate must survive Disconnect")
	}
	// Inside the breaker window / idle grace: kept.
	reg.sweepGates(time.Now().Add(time.Minute))
	if rawGateForKey(reg, "serial:SER-SWEEP") == nil {
		t.Fatal("a recently active identity must not be swept")
	}
	// Past every window and the grace: gone.
	reg.sweepGates(time.Now().Add(gateIdleGrace + providerBreakerWindow + time.Minute))
	if rawGateForKey(reg, "serial:SER-SWEEP") != nil {
		t.Fatal("an idle disconnected identity must be swept after the grace")
	}
}

// A gate created for an identity with no live session (the trailing flush's
// first fault, a serve outcome by stable id) counts its creation as activity:
// it is not idle-droppable before the grace, so the recorder that created it
// cannot lose the race against a sweep that runs before it takes the lock.
func TestFreshGateIsNotSweptBeforeTheGrace(t *testing.T) {
	reg := New(testLogger())
	ref := reg.gateForSession("sess-ghost")
	if ref.g == nil || ref.g.key != "sess-ghost" {
		t.Fatalf("ref = %+v, want a fresh session-keyed gate", ref)
	}
	reg.sweepGates(time.Now())
	if rawGateForKey(reg, "sess-ghost") != ref.g {
		t.Fatal("a just-created gate must survive the sweep until the grace")
	}
	reg.sweepGates(time.Now().Add(gateIdleGrace + time.Minute))
	if rawGateForKey(reg, "sess-ghost") != nil {
		t.Fatal("an idle unreferenced gate must be swept once past the grace")
	}
}
