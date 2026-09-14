package faultstate

import (
	"testing"
	"time"
)

// Regression for the prod fleet outage: providers wedged on "insufficient
// memory to load model" kept getting dispatches (hundreds of instant-503
// retry loops per provider) because nothing excluded the pair from routing.
func TestDispatchLoadCooldownLifecycle(t *testing.T) {
	r := newTestManager(testLogger())
	now := time.Now()

	if cooldownActive(r, "p1", "m1", now) {
		t.Fatal("cool-down active before any failure")
	}

	if !r.RecordDispatchLoadFailure("p1", "m1") {
		t.Fatal("first failure should start a NEW cool-down")
	}
	if r.RecordDispatchLoadFailure("p1", "m1") {
		t.Fatal("repeat failure should extend, not report a new cool-down")
	}

	if !cooldownActive(r, "p1", "m1", now) {
		t.Fatal("cool-down not active after failure")
	}
	// Scoped to the pair: same provider other model, and other provider same
	// model, still route.
	if cooldownActive(r, "p1", "m2", now) || cooldownActive(r, "p2", "m1", now) {
		t.Fatal("cool-down leaked beyond the failing provider-model pair")
	}

	if cooldownActive(r, "p1", "m1", now.Add(dispatchLoadCooldownTTL+time.Second)) {
		t.Fatal("cool-down survived past its TTL")
	}

	// A served request for the pair lifts the cool-down early.
	r.RecordDispatchLoadFailure("p1", "m1")
	r.ClearDispatchLoadCooldown("p1", "m1")
	if cooldownActive(r, "p1", "m1", now) {
		t.Fatal("cool-down survived ClearDispatchLoadCooldown")
	}
}
