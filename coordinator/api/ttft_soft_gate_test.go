package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestQueueMaxTTFTMsSoftVsHard pins whether the dispatch layer carries a
// first-content budget into PendingRequest.MaxTTFTMs.
//
// Ordinary soft mode gets zero. Hard mode and occupancy-enforce mode carry the
// prompt-scaled budget, though enforce consumes it only as a routing preference.
// Self-route and prefer-owner never receive the public SLA budget.
func TestQueueMaxTTFTMsSoftVsHard(t *testing.T) {
	deadline := 6 * time.Second
	public := selfRoutePolicy{}

	if got := queueMaxTTFTMs(public, deadline, false); got != 0 {
		t.Fatalf("soft public ceiling = %v, want 0 (no ceiling -> serve best-available)", got)
	}
	if got := queueMaxTTFTMs(public, deadline, true); got != float64(deadline.Milliseconds()) {
		t.Fatalf("hard public ceiling = %v, want %d", got, deadline.Milliseconds())
	}

	for _, withBudget := range []bool{false, true} {
		if got := queueMaxTTFTMs(selfRoutePolicy{enabled: true}, deadline, withBudget); got != 0 {
			t.Fatalf("self-route ceiling (withBudget=%v) = %v, want 0", withBudget, got)
		}
		if got := queueMaxTTFTMs(selfRoutePolicy{prefer: true}, deadline, withBudget); got != 0 {
			t.Fatalf("prefer-owner ceiling (withBudget=%v) = %v, want 0", withBudget, got)
		}
	}
}

func TestTTFTEnforceCarriesBudgetWithoutHardGate(t *testing.T) {
	previous := registry.TTFTAdmissionModeValue()
	t.Cleanup(func() { registry.SetTTFTAdmissionMode(previous) })

	s := &Server{ttftHardReject: true}
	registry.SetTTFTAdmissionMode(registry.TTFTAdmissionShadow)
	if !s.hardTTFTGateApplies(false) || !s.ttftRoutingBudgetApplies(false) {
		t.Fatal("shadow + hard reject must preserve the hard gate and carry its budget")
	}

	registry.SetTTFTAdmissionMode(registry.TTFTAdmissionEnforce)
	if s.hardTTFTGateApplies(false) {
		t.Fatal("enforce mode must disable TTFT estimate rejection")
	}
	if !s.ttftRoutingBudgetApplies(false) {
		t.Fatal("enforce mode must still carry the first-content budget for preference")
	}

	s.ttftHardReject = false
	if !s.ttftRoutingBudgetApplies(false) {
		t.Fatal("enforce mode must carry a budget even when legacy hard reject is off")
	}
	if s.ttftRoutingBudgetApplies(true) || s.hardTTFTGateApplies(true) {
		t.Fatal("vision requests must bypass token-prefill TTFT policy")
	}
}
