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
