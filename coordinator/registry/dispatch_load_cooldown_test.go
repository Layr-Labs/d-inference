package registry

import (
	"testing"
	"time"
)

func cooldownActive(r *Registry, providerID, modelID string, now time.Time) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.dispatchLoadCooldownActiveLocked(providerID, modelID, now)
}

// Regression for the prod fleet outage: providers wedged on "insufficient
// memory to load model" kept getting dispatches (hundreds of instant-503
// retry loops per provider) because nothing excluded the pair from routing.
func TestDispatchLoadCooldownLifecycle(t *testing.T) {
	r := New(testLogger())
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

// End-to-end through the dispatch selector: a cooling-down pair must not be
// picked, and must return to rotation once cleared.
func TestFindProviderWithTrustSkipsCoolingPair(t *testing.T) {
	r := New(testLogger())
	const model = aliasQAT
	p := registerProviderWithModel(r, "p1", model)
	makeProviderRoutable(p)

	if got := r.FindProviderWithTrust(model, ""); got == nil {
		t.Fatal("healthy provider not selected (fixture broken?)")
	}

	r.RecordDispatchLoadFailure(p.ID, model)
	if got := r.FindProviderWithTrust(model, ""); got != nil {
		t.Fatal("cooling-down provider was selected for dispatch")
	}

	r.ClearDispatchLoadCooldown(p.ID, model)
	if got := r.FindProviderWithTrust(model, ""); got == nil {
		t.Fatal("provider not selected after cool-down cleared")
	}
}

// The production dispatch hot path is ReserveProviderEx (not
// FindProviderWithTrust). A cooling-down pair must be excluded there too,
// otherwise the cool-down is cosmetic and the retry storm continues.
func TestReserveProviderExSkipsCoolingPair(t *testing.T) {
	reg := New(testLogger())
	model := "cooldown-reserve-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 200)

	req := func(id string) *PendingRequest {
		return &PendingRequest{RequestID: id, Model: model, RequestedMaxTokens: 128}
	}

	selected, _ := reg.ReserveProviderEx(model, req("r1"))
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil for a healthy provider (fixture broken?)")
	}
	// Free the slot so the next reservation is gated only by the cool-down.
	p.RemovePending("r1")

	reg.RecordDispatchLoadFailure(p.ID, model)
	if selected, _ := reg.ReserveProviderEx(model, req("r2")); selected != nil {
		t.Fatal("ReserveProviderEx selected a cooling-down provider (cool-down not on the hot path)")
	}

	reg.ClearDispatchLoadCooldown(p.ID, model)
	if selected, _ := reg.ReserveProviderEx(model, req("r3")); selected == nil {
		t.Fatal("ReserveProviderEx returned nil after the cool-down was cleared")
	}
}

func TestDispatchLoadCooldownClearedOnRegister(t *testing.T) {
	r := New(testLogger())
	r.RecordDispatchLoadFailure("p1", "m1")
	r.RecordDispatchLoadFailure("p1", "m2")

	r.mu.Lock()
	r.clearDispatchLoadCooldownsLocked("p1")
	r.mu.Unlock()

	now := time.Now()
	if cooldownActive(r, "p1", "m1", now) || cooldownActive(r, "p1", "m2", now) {
		t.Fatal("re-registration must clear the provider's cool-downs (fresh process, fresh memory)")
	}
}

func TestDispatchLoadCooldownSweepBoundsMap(t *testing.T) {
	r := New(testLogger())
	// Insert >1024 entries, then force them all past expiry by recording a
	// fresh failure after the TTL — the opportunistic sweep must drop them.
	for i := 0; i < 1100; i++ {
		r.RecordDispatchLoadFailure("dead-provider-"+string(rune('a'+i%26))+string(rune('0'+i%10))+string(rune('0'+(i/10)%10))+string(rune('0'+(i/100)%10)), "m")
	}
	r.mu.Lock()
	for k := range r.dispatchLoadCooldowns {
		r.dispatchLoadCooldowns[k] = time.Now().Add(-time.Second)
	}
	size := len(r.dispatchLoadCooldowns)
	r.mu.Unlock()
	if size < 1000 {
		t.Fatalf("setup produced too few distinct entries: %d", size)
	}

	r.RecordDispatchLoadFailure("live", "m")

	r.mu.Lock()
	after := len(r.dispatchLoadCooldowns)
	r.mu.Unlock()
	if after != 1 {
		t.Fatalf("sweep should leave only the live entry, got %d", after)
	}
}
