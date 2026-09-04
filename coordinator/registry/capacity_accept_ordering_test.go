package registry

import (
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
