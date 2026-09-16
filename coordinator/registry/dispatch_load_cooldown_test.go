package registry

import (
	"testing"
	"time"
)

func cooldownActive(r *Registry, providerID, modelID string, now time.Time) bool {
	return r.dispatchLoadCooled(providerID, modelID, now)
}

// The production dispatch hot path is ReserveProviderEx. A cooling-down pair
// must be excluded there, otherwise the cool-down is cosmetic and the retry
// storm continues.
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

// Regression for the reconnect exploit: re-registration used to clear a
// provider's dispatch-load cool-downs, so a churning box re-entered routing
// instantly after every bounce. The cool-down must now survive registration
// and expire only via its TTL or a served request.
func TestDispatchLoadCooldownSurvivesRegister(t *testing.T) {
	r := New(testLogger())
	r.RecordDispatchLoadFailure("p1", "m1")
	r.RecordDispatchLoadFailure("p1", "m2")

	r.Register("p1", nil, testRegisterMessage())

	now := time.Now()
	if !cooldownActive(r, "p1", "m1", now) || !cooldownActive(r, "p1", "m2", now) {
		t.Fatal("re-registration must NOT clear the provider's cool-downs (reconnect churn exploit)")
	}
	if cooldownActive(r, "p1", "m1", now.Add(dispatchLoadCooldownTTL+time.Second)) {
		t.Fatal("cool-down must still expire via its TTL")
	}
}

func TestDispatchLoadCooldownSweepBoundsMap(t *testing.T) {
	r := New(testLogger())
	// >1024 identity-less sessions record a load failure and vanish. Once the
	// cooldowns expire and the idle grace passes, the gate sweep must drop
	// every one of their gates; a connected provider's gate always survives.
	for i := 0; i < 1100; i++ {
		r.RecordDispatchLoadFailure("dead-provider-"+string(rune('a'+i%26))+string(rune('0'+i%10))+string(rune('0'+(i/10)%10))+string(rune('0'+(i/100)%10)), "m")
	}
	if n := r.gateCount(); n < 1000 {
		t.Fatalf("setup produced too few distinct gates: %d", n)
	}
	live := makeSchedulerProvider(t, r, "live", "m", 50)
	r.RecordDispatchLoadFailure(live.ID, "m")

	r.sweepGates(time.Now().Add(gateIdleGrace + dispatchLoadCooldownTTL + time.Second))

	if after := r.gateCount(); after != 1 {
		t.Fatalf("sweep should leave only the live provider's gate, got %d", after)
	}
	if rawGateForKey(r, live.ID) == nil {
		t.Fatal("the connected provider's gate must never be swept")
	}
}
