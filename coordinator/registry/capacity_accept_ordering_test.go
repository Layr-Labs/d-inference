package registry

import (
	"testing"
	"time"
)

// TestCapacityAcceptObservedBeforeClampDoesNotProveRelease: the budget clamp's
// release condition (b) is "an accept landed AFTER the clamp armed". An accept
// observed before the clamping reject but applied after it must not satisfy
// it, even once a fresh heartbeat has satisfied condition (a); an accept
// observed after the clamp does.
func TestCapacityAcceptObservedBeforeClampDoesNotProveRelease(t *testing.T) {
	r := New(testLogger())
	if !r.faults.Policy().BudgetClamp.Enabled {
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
