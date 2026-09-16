package faultstate

import (
	"testing"
	"time"
)

// A gate created for an identity with no live session (the trailing flush's
// first fault, a serve outcome by stable id) counts its creation as activity:
// it is not idle-droppable before the grace, so the recorder that created it
// cannot lose the race against a sweep that runs before it takes the lock.
func TestFreshGateIsNotSweptBeforeTheGrace(t *testing.T) {
	reg := newTestManager(testLogger())
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
