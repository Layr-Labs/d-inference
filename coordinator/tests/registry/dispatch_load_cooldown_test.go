package registry_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Regression for the prod fleet outage: providers wedged on "insufficient
// memory to load model" kept getting dispatches (hundreds of instant-503
// retry loops per provider) because nothing excluded the pair from routing.
func TestDispatchLoadCooldownLifecycle(t *testing.T) {
	r, gates, _ := newFaultGateFixture()
	now := time.Now()

	if cooldownActive(gates, "p1", "m1", now) {
		t.Fatal("cool-down active before any failure")
	}

	if !r.RecordDispatchLoadFailure("p1", "m1") {
		t.Fatal("first failure should start a NEW cool-down")
	}
	if r.RecordDispatchLoadFailure("p1", "m1") {
		t.Fatal("repeat failure should extend, not report a new cool-down")
	}

	if !cooldownActive(gates, "p1", "m1", now) {
		t.Fatal("cool-down not active after failure")
	}
	// Scoped to the pair: same provider other model, and other provider same
	// model, still route.
	if cooldownActive(gates, "p1", "m2", now) || cooldownActive(gates, "p2", "m1", now) {
		t.Fatal("cool-down leaked beyond the failing provider-model pair")
	}

	if cooldownActive(gates, "p1", "m1", now.Add(dispatchLoadCooldownTTL+time.Second)) {
		t.Fatal("cool-down survived past its TTL")
	}

	// A served request for the pair lifts the cool-down early.
	r.RecordDispatchLoadFailure("p1", "m1")
	r.ClearDispatchLoadCooldown("p1", "m1")
	if cooldownActive(gates, "p1", "m1", now) {
		t.Fatal("cool-down survived ClearDispatchLoadCooldown")
	}
}

// Re-registration must retain identity cooldowns instead of allowing a
// reconnecting provider straight back into routing.
func TestDispatchLoadCooldownSurvivesRegister(t *testing.T) {
	r, gates, _ := newFaultGateFixture()
	r.RecordDispatchLoadFailure("p1", "m1")
	r.RecordDispatchLoadFailure("p1", "m2")

	r.Register("p1", nil, testRegisterMessage())

	now := time.Now()
	if !cooldownActive(gates, "p1", "m1", now) || !cooldownActive(gates, "p1", "m2", now) {
		t.Fatal("re-registration must NOT clear the provider's cool-downs (reconnect churn exploit)")
	}
	if cooldownActive(gates, "p1", "m1", now.Add(dispatchLoadCooldownTTL+time.Second)) {
		t.Fatal("cool-down must still expire via its TTL")
	}
}

func TestDispatchLoadCooldownSweepBoundsMap(t *testing.T) {
	r, gates, clock := newFaultGateFixture()
	// Keep the original 1100 distinct dead identities and a connected survivor.
	for i := 0; i < 1100; i++ {
		r.RecordDispatchLoadFailure("dead-provider-"+string(rune('a'+i%26))+string(rune('0'+i%10))+string(rune('0'+(i/10)%10))+string(rune('0'+(i/100)%10)), "m")
	}
	if n := gates.Sweep(clock.Now()); n < 1000 {
		t.Fatalf("setup produced too few distinct gates: %d", n)
	}
	live := makeSchedulerProvider(t, r, "live", "m", 50)
	r.RecordDispatchLoadFailure(live.ID, "m")

	after := gates.Sweep(clock.Now().Add(gateIdleGrace + dispatchLoadCooldownTTL + time.Second))
	if after != 1 {
		t.Fatalf("sweep should leave only the live provider's gate, got %d", after)
	}
	if !gates.ViewIdentity(live.ID).Present() {
		t.Fatal("the connected provider's gate must never be swept")
	}
}

// The production dispatch hot path is ReserveProviderEx. A cooling-down pair
// must be excluded there, otherwise the cool-down is cosmetic and the retry
// storm continues.
func TestReserveProviderExSkipsCoolingPair(t *testing.T) {
	reg := production.New(testLogger())
	model := "cooldown-reserve-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 200)

	req := func(id string) *production.PendingRequest {
		return &production.PendingRequest{RequestID: id, Model: model, RequestedMaxTokens: 128}
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
