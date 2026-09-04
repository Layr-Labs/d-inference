package registry

import (
	"fmt"
	"testing"
	"time"
)

// capacityStrikesOf returns the pair's recorded reject strikes (chronological).
func capacityStrikesOf(r *Registry, providerID, modelID string) []time.Time {
	r.mu.RLock()
	defer r.mu.RUnlock()
	strikes := r.capacityRejectStrikes[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
	return append([]time.Time(nil), strikes...)
}

// TestCapacityAcceptAppliedLateKeepsStrikeRecordedAfterObservation: the
// commit-time accept is observed at the first content chunk but applied when
// its goroutine finally holds the registry write lock (~190 ms behind queued
// writers in production). A capacity reject for the same pair recorded in that
// gap happened AFTER the accept and must survive it; a strike recorded before
// the observation is still cleared. The test holds the write lock, starts the
// accept, records one older and one newer strike while the accept is blocked,
// then releases the lock.
func TestCapacityAcceptAppliedLateKeepsStrikeRecordedAfterObservation(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-late-accept", "gemma-4-26b-8bit"
	key := capacityRejectKey{ProviderID: provider, ModelID: model}

	observedAt := time.Now()
	r.mu.Lock()
	applied := make(chan struct{})
	go func() {
		defer close(applied)
		r.RecordCapacityAcceptObserved(provider, model, observedAt, true)
	}()
	// While the accept waits for the lock: one strike from before the accept
	// was observed, one from after (the reject that must not be erased).
	older := observedAt.Add(-time.Second)
	time.Sleep(2 * time.Millisecond)
	newer := time.Now()
	r.capacityRejectStrikes[key] = []time.Time{older, newer}
	r.mu.Unlock()
	<-applied

	got := capacityStrikesOf(r, provider, model)
	if len(got) != 1 || !got[0].Equal(newer) {
		t.Fatalf("strikes after a late-applied accept = %v, want exactly the strike recorded after the observation (%v)", got, newer)
	}

	// The survivor is the first strike of a possible new streak: Threshold-1
	// further rejects with no accept in between trip the cooldown.
	threshold := r.capacityCooldownCfg.Threshold
	for i := 2; i < threshold; i++ {
		if r.RecordCapacityReject(provider, model) {
			t.Fatalf("reject %d/%d tripped early", i, threshold)
		}
	}
	if !r.RecordCapacityReject(provider, model) {
		t.Fatalf("reject %d/%d did not trip: the strike recorded after the accept was not counted", threshold, threshold)
	}

	// An accept observed NOW (a synchronous caller) still clears everything.
	r.RecordCapacityAccept(provider, model)
	if got := capacityStrikesOf(r, provider, model); len(got) != 0 {
		t.Fatalf("strikes after a current accept = %v, want none", got)
	}
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("cooldown still active after a current accept")
	}
}

// TestCapacityAcceptObservedBeforeClampDoesNotProveRelease: the budget clamp's
// release condition (b) is "an accept landed AFTER the clamp armed". An accept
// observed before the clamping reject but applied after it must not satisfy
// it, even once a fresh heartbeat has satisfied condition (a); an accept
// observed after the clamp does.
func TestCapacityAcceptObservedBeforeClampDoesNotProveRelease(t *testing.T) {
	r := New(testLogger())
	if !r.budgetClampCfg.Enabled {
		t.Fatal("budget clamp disabled in the test environment")
	}
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-late-accept", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	observedAt := time.Now()
	time.Sleep(2 * time.Millisecond)
	if r.RecordCapacityReject(p.ID, model) {
		t.Fatal("one reject must not trip the pair cooldown")
	}
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("clamp must be active after one capacity reject")
	}
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("a fresh heartbeat alone must not release the clamp")
	}

	// The accept predates the clamp: it is not the post-clamp accept the
	// release proof needs.
	r.RecordCapacityAcceptObserved(p.ID, model, observedAt, true)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("an accept observed BEFORE the clamping reject released the clamp")
	}

	// An accept observed after the clamp completes the proof.
	r.RecordCapacityAcceptObserved(p.ID, model, time.Now(), true)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("fresh heartbeat + accept observed after the clamp must release it")
	}
}

// capacityTripsOf returns the pair's cooldown trip count (0 = never tripped or
// accept-cleared).
func capacityTripsOf(r *Registry, providerID, modelID string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.capacityCooldownTrips[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
}

// TestCapacityAcceptAppliedLateKeepsCooldownArmedByNewerStrikes: while the
// commit-time accept waits for the write lock, Threshold rejects for the same
// pair can arrive and trip the cooldown. Every one of those strikes postdates
// the accept, so together they are the black-hole signature on their own; the
// late accept keeps the strikes (previous test) AND the cooldown they armed —
// otherwise the failing pair would be routable again until the next reject
// re-tripped it. The accept is applied through the real reject path with an
// observation time that predates the strikes, so the test is deterministic.
func TestCapacityAcceptAppliedLateKeepsCooldownArmedByNewerStrikes(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-late-accept-tripped", "gemma-4-26b-8bit"
	threshold := r.capacityCooldownCfg.Threshold

	observedAt := time.Now()
	time.Sleep(2 * time.Millisecond)
	for i := 1; i <= threshold; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped != (i == threshold) {
			t.Fatalf("reject %d/%d tripped=%v", i, threshold, tripped)
		}
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown not active after Threshold rejects")
	}

	// The accept observed before every one of those strikes is applied now.
	r.RecordCapacityAcceptObserved(provider, model, observedAt, true)
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("a late-applied accept cleared a cooldown armed by strikes recorded after it")
	}
	if got := capacityTripsOf(r, provider, model); got != 1 {
		t.Fatalf("trip count after the late accept = %d, want 1 (the backoff state survives with the cooldown)", got)
	}
	if got := capacityStrikesOf(r, provider, model); len(got) != threshold {
		t.Fatalf("strikes after the late accept = %d, want all %d newer strikes", len(got), threshold)
	}

	// An accept observed NOW — after the strikes — is the real recovery signal.
	r.RecordCapacityAccept(provider, model)
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown still active after a current accept")
	}
	if got := capacityTripsOf(r, provider, model); got != 0 {
		t.Fatalf("trip count after a current accept = %d, want 0", got)
	}
	if got := capacityStrikesOf(r, provider, model); len(got) != 0 {
		t.Fatalf("strikes after a current accept = %v, want none", got)
	}
}

// TestCapacityAcceptAppliedLateClearsCooldownTrippedWithOlderStrikes: the
// cooldown survives a late accept only when the surviving strikes reach the
// threshold by themselves. A trip that needed strikes from BEFORE the accept
// was observed is disproven by it — in the correct order the accept would have
// cleared those older strikes and the newer ones alone would not have tripped
// — so the entry and trip count are cleared and the survivors start a fresh
// streak.
func TestCapacityAcceptAppliedLateClearsCooldownTrippedWithOlderStrikes(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-late-accept-mixed", "gemma-4-26b-8bit"
	threshold := r.capacityCooldownCfg.Threshold
	const newer = 2
	if threshold <= newer {
		t.Skipf("threshold %d leaves no room for older strikes", threshold)
	}

	for i := 1; i <= threshold-newer; i++ {
		if r.RecordCapacityReject(provider, model) {
			t.Fatalf("older reject %d tripped early", i)
		}
	}
	time.Sleep(2 * time.Millisecond)
	observedAt := time.Now()
	time.Sleep(2 * time.Millisecond)
	for i := 1; i <= newer; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped != (i == newer) {
			t.Fatalf("newer reject %d/%d tripped=%v", i, newer, tripped)
		}
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown not active after Threshold rejects")
	}

	r.RecordCapacityAcceptObserved(provider, model, observedAt, true)
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("a cooldown that needed strikes from before the accept survived it")
	}
	if got := capacityTripsOf(r, provider, model); got != 0 {
		t.Fatalf("trip count after the late accept = %d, want 0", got)
	}
	if got := capacityStrikesOf(r, provider, model); len(got) != newer {
		t.Fatalf("strikes after the late accept = %d, want the %d recorded after the observation", len(got), newer)
	}

	// The survivors are the start of a new streak: threshold-newer more
	// rejects with no accept in between trip the pair again, from trips == 0.
	for i := newer + 1; i < threshold; i++ {
		if r.RecordCapacityReject(provider, model) {
			t.Fatalf("reject %d/%d tripped early", i, threshold)
		}
	}
	if !r.RecordCapacityReject(provider, model) {
		t.Fatalf("reject %d/%d did not trip", threshold, threshold)
	}
	if got := capacityTripsOf(r, provider, model); got != 1 {
		t.Fatalf("trip count after the re-trip = %d, want 1 (fresh backoff)", got)
	}
}

// A late accept clears pre-observation exponential history even when enough
// later rejects independently justify a new cooldown.
func TestCapacityAcceptRebuildsNewCooldownWithFreshBackoff(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(fmt.Sprintf("old_active_%v", active), func(t *testing.T) {
			r := New(nil)
			const provider, model = "old-backoff", "model"
			key := capacityRejectKey{ProviderID: provider, ModelID: model}
			observed := time.Now().Add(-time.Second)
			oldExpiry := time.Now().Add(-time.Second)
			if active {
				oldExpiry = time.Now().Add(5 * time.Minute)
			}
			r.mu.Lock()
			r.capacityCooldownTrips[key] = 4
			r.capacityCooldowns[key] = &capacityCooldownEntry{expiry: oldExpiry}
			r.mu.Unlock()
			for range r.capacityCooldownCfg.Threshold {
				r.RecordCapacityReject(provider, model)
			}
			strikes := capacityStrikesOf(r, provider, model)
			wantExpiry := strikes[r.capacityCooldownCfg.Threshold-1].Add(r.capacityCooldownCfg.BaseTTL)
			r.RecordCapacityAcceptObserved(provider, model, observed, true)
			r.mu.RLock()
			got, trips := *r.capacityCooldowns[key], r.capacityCooldownTrips[key]
			r.mu.RUnlock()
			if trips != 1 || !got.expiry.Equal(wantExpiry) {
				t.Fatalf("rebuilt cooldown: trips=%d expiry=%v, want 1/%v", trips, got.expiry, wantExpiry)
			}
		})
	}
}

func TestCapacityAcceptRebuildPreservesNewProbe(t *testing.T) {
	r := New(nil)
	key := capacityRejectKey{ProviderID: "probe", ModelID: "model"}
	now := time.Now()
	r.capacityCooldownCfg = capacityCooldownConfig{Threshold: 2, Window: time.Minute, BaseTTL: time.Second, MaxTTL: time.Minute}
	r.capacityRejectStrikes[key] = []time.Time{now.Add(-4 * time.Second), now.Add(-3 * time.Second)}
	probeAt := now.Add(-time.Second)
	r.capacityCooldowns[key] = &capacityCooldownEntry{expiry: now.Add(-2 * time.Second), probeAt: probeAt}
	r.capacityCooldownTrips[key] = 4
	r.RecordCapacityAcceptObserved(key.ProviderID, key.ModelID, now.Add(-5*time.Second), false)
	if entry := r.capacityCooldowns[key]; entry == nil || !entry.probeAt.Equal(probeAt) {
		t.Fatalf("lost current probe: %+v", entry)
	}
	if !r.CapacityCooldownActive(key.ProviderID, key.ModelID) {
		t.Fatal("rebuild allowed a second probe while the first is pending")
	}
}
