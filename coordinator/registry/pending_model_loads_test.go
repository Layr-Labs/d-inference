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

func pendingLoadExpiry(r *Registry, providerID, modelID string) (time.Time, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	exp, ok := r.pendingModelLoads[modelLoadKey(providerID, modelID)]
	return exp, ok
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

// TestMemoryBackoffShortensPendingLoadCooldown checks that a non-draining load
// failure (insufficient memory et al.) shortens the pending cooldown from the
// full 2-min TTL to the short memory backoff so a provider whose memory frees in
// seconds is reconsidered well inside the 120s queue window.
func TestMemoryBackoffShortensPendingLoadCooldown(t *testing.T) {
	r := New(testLogger())
	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, time.Now())

	r.BackoffPendingModelLoadForMemory("p1", "m1")

	r.expirePendingModelLoads(time.Now().Add(pendingModelLoadMemoryBackoff - 5*time.Second))
	if !hasPendingLoad(r, "p1") {
		t.Fatal("memory backoff cleared too early")
	}

	r.expirePendingModelLoads(time.Now().Add(pendingModelLoadMemoryBackoff + time.Second))
	if hasPendingLoad(r, "p1") {
		t.Fatal("memory backoff survived past pendingModelLoadMemoryBackoff")
	}
}

// TestMemoryBackoffRestampsFullTTLEntry pins the re-stamp: a fresh reservation
// stamps now+pendingModelLoadTTL (2 min); the memory backoff must rewrite that
// expiry DOWN to ~now+pendingModelLoadMemoryBackoff (not merely clear it).
func TestMemoryBackoffRestampsFullTTLEntry(t *testing.T) {
	r := New(testLogger())
	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, time.Now())

	full, ok := pendingLoadExpiry(r, "p1", "m1")
	if !ok {
		t.Fatal("reservation did not create a pending entry")
	}

	r.BackoffPendingModelLoadForMemory("p1", "m1")

	shortened, ok := pendingLoadExpiry(r, "p1", "m1")
	if !ok {
		t.Fatal("memory backoff dropped the pending entry")
	}
	if !shortened.Before(full) {
		t.Fatalf("memory backoff did not shorten expiry: full=%v shortened=%v", full, shortened)
	}
	if d := time.Until(shortened); d > pendingModelLoadMemoryBackoff+2*time.Second {
		t.Fatalf("memory backoff expiry too far out: %v (want <= %v)", d, pendingModelLoadMemoryBackoff)
	}
}

// TestMemoryBackoffAppliesWithoutPriorReservation mirrors the drain case: a
// failure status can arrive for a load whose reservation already expired/cleared.
func TestMemoryBackoffAppliesWithoutPriorReservation(t *testing.T) {
	r := New(testLogger())
	r.BackoffPendingModelLoadForMemory("p1", "m1")

	if !hasPendingLoad(r, "p1") {
		t.Fatal("memory backoff did not create a pending entry")
	}

	r.expirePendingModelLoads(time.Now().Add(pendingModelLoadMemoryBackoff + time.Second))
	if hasPendingLoad(r, "p1") {
		t.Fatal("memory backoff survived past pendingModelLoadMemoryBackoff")
	}
}

// TestMemoryBackoffReapedByWarmPoolSweep proves the lazy reaper that runs every
// warm-pool tick (~10s), pendingModelLoadCount, drops the short entry once it
// expires so the provider becomes plannable again deterministically.
func TestMemoryBackoffReapedByWarmPoolSweep(t *testing.T) {
	r := New(testLogger())
	r.BackoffPendingModelLoadForMemory("p1", "m1")

	if n := r.pendingModelLoadCount(time.Now()); n != 1 {
		t.Fatalf("pendingModelLoadCount = %d before expiry, want 1", n)
	}
	if n := r.pendingModelLoadCount(time.Now().Add(pendingModelLoadMemoryBackoff + time.Second)); n != 0 {
		t.Fatalf("pendingModelLoadCount = %d after expiry, want 0 (warm-pool sweep must reap)", n)
	}
	if hasPendingLoad(r, "p1") {
		t.Fatal("warm-pool sweep did not reap the expired memory backoff")
	}
}

// TestDisconnectClearsPendingModelLoad pins the deterministic-clearing
// invariant: a provider going away must drop its pending model-load state
// (both maps) so a reconnect starts clean and the planner is not suppressed.
func TestDisconnectClearsPendingModelLoad(t *testing.T) {
	r := New(testLogger())
	r.Register("p1", nil, testRegisterMessage())
	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, time.Now())
	if !hasPendingLoad(r, "p1") {
		t.Fatal("reservation did not create a pending entry")
	}

	r.Disconnect("p1")

	if hasPendingLoad(r, "p1") {
		t.Fatal("Disconnect did not clear the provider's pending model load")
	}
	r.mu.RLock()
	_, startedLeft := r.pendingModelLoadStarted[modelLoadKey("p1", "m1")]
	r.mu.RUnlock()
	if startedLeft {
		t.Fatal("Disconnect left a dangling pendingModelLoadStarted entry")
	}
}
