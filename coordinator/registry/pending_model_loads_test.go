package registry

import (
	"testing"
	"time"
)

func hasPendingLoad(r *Registry, providerID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerHasPendingLoad(providerID, time.Now())
}

func pendingLoadExpiry(r *Registry, providerID, modelID string) (time.Time, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	exp, ok := r.pendingModelLoads[modelLoadKey{ProviderID: providerID, ModelID: modelID}]
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

func TestHasPendingModelLoadMatchesExactUnexpiredCommand(t *testing.T) {
	r := New(testLogger())
	if r.HasPendingModelLoad("p1", "m1") {
		t.Fatal("missing command reported as pending")
	}

	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, time.Now())
	if !r.HasPendingModelLoad("p1", "m1") {
		t.Fatal("coordinator-issued command was not reported pending")
	}
	if r.HasPendingModelLoad("p1", "m2") || r.HasPendingModelLoad("p2", "m1") {
		t.Fatal("pending command matched a different provider/model pair")
	}

	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey{ProviderID: "p1", ModelID: "m1"}] = time.Now().Add(-time.Second)
	r.mu.Unlock()
	if r.HasPendingModelLoad("p1", "m1") {
		t.Fatal("expired command reported as pending")
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
	_, startedLeft := r.pendingModelLoadStarted[modelLoadKey{ProviderID: "p1", ModelID: "m1"}]
	r.mu.RUnlock()
	if startedLeft {
		t.Fatal("Disconnect left a dangling pendingModelLoadStarted entry")
	}
}

// TestExpiredPendingLoadIgnoredWithoutSweep pins lazy expiry: an expired
// entry is invisible to every planner read (providerHasPendingLoad,
// reservePendingModelLoads' per-provider check, PendingModelLoadDuration)
// with no sweep having run, and the warm-pool tick's pendingModelLoadCount
// reaps it.
func TestExpiredPendingLoadIgnoredWithoutSweep(t *testing.T) {
	r := New(testLogger())
	now := time.Now()
	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, now)
	if !hasPendingLoad(r, "p1") {
		t.Fatal("fresh reservation not visible")
	}
	if d := r.PendingModelLoadDuration("p1", "m1"); d <= 0 {
		t.Fatalf("live reservation duration = %v, want > 0", d)
	}

	// Back-date the entry past its TTL without running any sweep.
	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey{ProviderID: "p1", ModelID: "m1"}] = now.Add(-time.Second)
	r.mu.Unlock()

	if hasPendingLoad(r, "p1") {
		t.Fatal("expired entry still reported as pending")
	}
	if d := r.PendingModelLoadDuration("p1", "m1"); d != 0 {
		t.Fatalf("expired entry duration = %v, want 0", d)
	}
	again := r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m2"}}, now)
	if len(again) != 1 {
		t.Fatal("provider with only an expired entry was not reservable")
	}
	r.mu.RLock()
	_, stale := r.pendingModelLoads[modelLoadKey{ProviderID: "p1", ModelID: "m1"}]
	r.mu.RUnlock()
	if !stale {
		t.Fatal("expired entry was deleted by a read path; deletion belongs to the write-locked sweeps")
	}
	if n := r.pendingModelLoadCount(now); n != 1 {
		t.Fatalf("pendingModelLoadCount = %d, want 1 (only the live m2 entry)", n)
	}
	r.mu.RLock()
	_, stale = r.pendingModelLoads[modelLoadKey{ProviderID: "p1", ModelID: "m1"}]
	r.mu.RUnlock()
	if stale {
		t.Fatal("warm-pool sweep did not reap the expired entry")
	}
}

// TestClearIneligibleReapsExpiredEntries: the runtime-policy sweep, already
// under the write lock, reaps expired entries without counting them as
// ineligible releases.
func TestClearIneligibleReapsExpiredEntries(t *testing.T) {
	r := New(testLogger())
	r.Register("p1", nil, testRegisterMessage())
	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey{ProviderID: "p1", ModelID: "m-expired"}] = time.Now().Add(-time.Second)
	r.pendingModelLoadStarted[modelLoadKey{ProviderID: "p1", ModelID: "m-expired"}] = time.Now().Add(-time.Minute)
	r.mu.Unlock()
	if cleared := r.ClearIneligiblePendingModelLoads("p1"); cleared != 0 {
		t.Fatalf("expired entry counted as an ineligible release: cleared = %d", cleared)
	}
	r.mu.RLock()
	_, left := r.pendingModelLoads[modelLoadKey{ProviderID: "p1", ModelID: "m-expired"}]
	_, startedLeft := r.pendingModelLoadStarted[modelLoadKey{ProviderID: "p1", ModelID: "m-expired"}]
	r.mu.RUnlock()
	if left || startedLeft {
		t.Fatal("ClearIneligiblePendingModelLoads left the expired entry (or its start stamp) behind")
	}
}

// TestTriggerModelSwapsTakesNoWriteLockWhenNothingToLoad: with a queued model
// nobody can load, TriggerModelSwaps must complete while another goroutine
// holds r.mu for reading — i.e. it takes no write lock (a writer would wait
// for the reader and the call would hang). Fails before the change, where
// every TriggerModelSwaps called expirePendingModelLoads under r.mu.Lock.
func TestTriggerModelSwapsTakesNoWriteLockWhenNothingToLoad(t *testing.T) {
	r := New(testLogger())
	r.SetQueue(NewRequestQueue(8, 30*time.Second))
	const model = "no-loader-model"
	r.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 15}})
	if err := r.Queue().Enqueue(&QueuedRequest{RequestID: "q", Model: model, Pending: &PendingRequest{RequestID: "q", Model: model}}); err != nil {
		t.Fatal(err)
	}
	// A stale entry that the old code would have swept under the write lock.
	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey{ProviderID: "gone", ModelID: model}] = time.Now().Add(-time.Second)
	r.mu.Unlock()

	r.mu.RLock()
	done := make(chan struct{})
	go func() {
		defer close(done)
		r.TriggerModelSwaps()
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		r.mu.RUnlock()
		t.Fatal("TriggerModelSwaps blocked on r.mu.Lock while a reader held the lock")
	}
	r.mu.RUnlock()
}
