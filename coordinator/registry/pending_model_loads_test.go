package registry

import (
	"testing"
	"time"
)

func hasPendingLoad(r *Registry, providerID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerHasPendingLoad(providerID)
}

func TestPendingModelLoadReserveAndExpiry(t *testing.T) {
	r := New(testLogger())
	now := time.Now()

	reserved := r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, now)
	if len(reserved) != 1 {
		t.Fatalf("expected 1 reserved action, got %d", len(reserved))
	}

	// While the entry lives, the provider must not be reserved again — not
	// even for a different model (single-slot swap oscillation guard).
	again := r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m2"}}, now.Add(time.Minute))
	if len(again) != 0 {
		t.Fatal("provider with a pending load was reserved again")
	}

	r.expirePendingModelLoads(now.Add(pendingModelLoadTTL - time.Second))
	if !hasPendingLoad(r, "p1") {
		t.Fatal("pending load expired before the TTL")
	}

	r.expirePendingModelLoads(now.Add(pendingModelLoadTTL + time.Second))
	if hasPendingLoad(r, "p1") {
		t.Fatal("pending load survived past the TTL")
	}
}

func TestDrainBackoffShortensPendingLoadCooldown(t *testing.T) {
	r := New(testLogger())
	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, time.Now())

	// A drain rejection re-stamps the entry with the short backoff: long
	// enough to keep the planner off a provider that is about to restart,
	// short enough that an aborted restart leaves it plannable again well
	// inside the queue window.
	r.BackoffPendingModelLoadForDrain("p1", "m1")

	r.expirePendingModelLoads(time.Now().Add(pendingModelLoadDrainBackoff - 5*time.Second))
	if !hasPendingLoad(r, "p1") {
		t.Fatal("drain backoff cleared too early")
	}

	r.expirePendingModelLoads(time.Now().Add(pendingModelLoadDrainBackoff + time.Second))
	if hasPendingLoad(r, "p1") {
		t.Fatal("drain backoff survived past pendingModelLoadDrainBackoff")
	}
}

func TestDrainBackoffAppliesWithoutPriorReservation(t *testing.T) {
	// The coordinator may learn of a drain rejection for a load_model it sent
	// before a restart (entry already expired or cleared). The backoff must
	// still record the provider as temporarily unplannable.
	r := New(testLogger())
	r.BackoffPendingModelLoadForDrain("p1", "m1")

	if !hasPendingLoad(r, "p1") {
		t.Fatal("drain backoff did not create a pending entry")
	}

	r.expirePendingModelLoads(time.Now().Add(pendingModelLoadDrainBackoff + time.Second))
	if hasPendingLoad(r, "p1") {
		t.Fatal("drain backoff survived past pendingModelLoadDrainBackoff")
	}
}
