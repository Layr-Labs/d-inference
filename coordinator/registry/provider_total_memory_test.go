package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// providerTotalMemoryGB is what every hardware-fit gate must size a machine
// from. It exists because an operator memory limit (provider-side
// `memory_limit_gb`) shows up ONLY in the heartbeat: registration keeps
// reporting raw hardware (the base-reward tier is priced from it), while
// `total_memory_gb` carries the capped figure. Sizing a fit check from
// registration would plan loads the provider's own gate then refuses.

func TestProviderTotalMemoryPrefersHeartbeat(t *testing.T) {
	p := &Provider{
		Hardware:        protocol.Hardware{MemoryGB: 256},
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 150},
	}
	if got := providerTotalMemoryGB(p); got != 150 {
		t.Errorf("providerTotalMemoryGB = %v, want 150 (the capped heartbeat value)", got)
	}
}

func TestProviderTotalMemoryFallsBackToRegistration(t *testing.T) {
	// Legacy provider (no BackendCapacity yet) and the pre-first-heartbeat
	// window both land here: registration hardware is all we have.
	if got := providerTotalMemoryGB(&Provider{
		Hardware: protocol.Hardware{MemoryGB: 64},
	}); got != 64 {
		t.Errorf("providerTotalMemoryGB with nil BackendCapacity = %v, want 64", got)
	}
	// A zero/absent total_memory_gb is not a claim of "0 GB" — fall back.
	if got := providerTotalMemoryGB(&Provider{
		Hardware:        protocol.Hardware{MemoryGB: 64},
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 0},
	}); got != 64 {
		t.Errorf("providerTotalMemoryGB with zero TotalMemoryGB = %v, want 64", got)
	}
}

// The behavioral consequence: a 256 GB box capped to 150 GB must NOT pass the
// static hardware-fit gate for a model only a 256 GB box could hold. Before the
// fix, cold-spill and the warm-pool load planner used registration memory and
// admitted it, then the provider's authoritative load gate refused.
func TestCappedProviderFailsHardwareFitForOversizedModel(t *testing.T) {
	capped := &Provider{
		Hardware:        protocol.Hardware{MemoryGB: 256},
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 150},
	}
	uncapped := &Provider{
		Hardware:        protocol.Hardware{MemoryGB: 256},
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 256},
	}

	const minRAMGb = 200 // catalog-authoritative requirement
	const sizeGB = 180.0

	if modelFitsHardware(minRAMGb, sizeGB, providerTotalMemoryGB(capped)) {
		t.Error("a 150 GB-capped provider must not pass the fit gate for a 200 GB model")
	}
	if !modelFitsHardware(minRAMGb, sizeGB, providerTotalMemoryGB(uncapped)) {
		t.Error("an uncapped 256 GB provider must still pass the fit gate")
	}
	// Regression guard on the old expression: registration memory alone would
	// have admitted the capped box.
	if !modelFitsHardware(minRAMGb, sizeGB, float64(capped.Hardware.MemoryGB)) {
		t.Error("precondition: registration memory admits the model (that was the bug)")
	}
}
