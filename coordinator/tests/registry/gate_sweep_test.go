package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Tests for the gate sweep (gate_sweep.go): the liveness rule and the idle
// grace, including a fresh gate's creation counting as activity.

// The sweep never drops a gate a connected session references, drops an
// identity-less session's gate at Disconnect, and drops a disconnected
// identity's gate only once it is idle AND past the idle grace.
func TestGateSweepLivenessRule(t *testing.T) {
	gates := identitygate.New(testLogger(), nil)
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	anon := makeSchedulerProvider(t, reg, "sess-anon", "m", 100)
	attested := attestSchedulerProvider(t, reg, "sess-att", "m", "SER-SWEEP", 100)
	reg.RecordProviderOutcome(attested.ID, false, 500, "internal error")

	gates.Sweep(time.Now().Add(24 * time.Hour))
	if !gates.ViewIdentity(anon.ID).Present() || !gates.ViewIdentity("serial:SER-SWEEP").Present() {
		t.Fatal("gates with a connected session must survive any sweep")
	}

	reg.Disconnect(anon.ID)
	if gates.ViewIdentity(anon.ID).Present() {
		t.Fatal("an identity-less session's gate must be dropped at Disconnect")
	}

	reg.Disconnect(attested.ID)
	if !gates.ViewIdentity("serial:SER-SWEEP").Present() {
		t.Fatal("a stable identity's gate must survive Disconnect")
	}
	// Inside the breaker window / idle grace: kept.
	gates.Sweep(time.Now().Add(time.Minute))
	if !gates.ViewIdentity("serial:SER-SWEEP").Present() {
		t.Fatal("a recently active identity must not be swept")
	}
	// Past every window and the grace: gone.
	gates.Sweep(time.Now().Add(gateIdleGrace + identitygate.BreakerWindow + time.Minute))
	if gates.ViewIdentity("serial:SER-SWEEP").Present() {
		t.Fatal("an idle disconnected identity must be swept after the grace")
	}
}

// A gate created for an identity with no live session (the trailing flush's
// first fault, a serve outcome by stable id) counts its creation as activity:
// it is not idle-droppable before the grace, so the recorder that created it
// cannot lose the race against a sweep that runs before it takes the lock.
func TestFreshGateIsNotSweptBeforeTheGrace(t *testing.T) {
	gates := identitygate.New(testLogger(), nil)
	ref := gates.ResolveSession("sess-ghost", true)
	view := gates.ViewReference(ref)
	if !view.Present() || !view.SameIdentity(gates.ViewIdentity("sess-ghost")) {
		t.Fatalf("ref = %+v, want a fresh session-keyed gate", ref)
	}
	gates.Sweep(time.Now())
	if !gates.ViewIdentity("sess-ghost").SameIdentity(view) {
		t.Fatal("a just-created gate must survive the sweep until the grace")
	}
	gates.Sweep(time.Now().Add(gateIdleGrace + time.Minute))
	if gates.ViewIdentity("sess-ghost").Present() {
		t.Fatal("an idle unreferenced gate must be swept once past the grace")
	}
}
