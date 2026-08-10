package registry

import (
	"testing"
	"time"

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

// The behavioral consequence, driven through the REAL planner rather than the
// helper: a 256 GB box capped to 150 GB must not be planned a load only a
// 256 GB box could hold. Reverting the one-line call-site change in
// registry.go fails this test — asserting on providerTotalMemoryGB alone would
// not, since the helper would still be correct while nothing used it.
func TestLoadPlannerRespectsCappedTotalMemory(t *testing.T) {
	reg := New(testLogger())
	const model = "capped-box-oversized"
	// Catalog-authoritative requirement no capped box can satisfy.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 180, MinRAMGB: 200}})

	p := registerProviderWithModel(reg, "p1", model)
	makeProviderRoutable(p)
	now := time.Now()

	setMemory := func(totalMemoryGB float64) {
		p.mu.Lock()
		p.Hardware.MemoryGB = 256 // registration always reports raw hardware
		p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: totalMemoryGB}
		p.mu.Unlock()
	}

	// Uncapped: heartbeat equals physical, planner admits (precondition — this
	// is what the old registration-only expression always did).
	setMemory(256)
	if _, ok := reg.modelLoadCandidatePendingLocked(p, model, now); !ok {
		t.Fatal("precondition: an uncapped 256 GB box must be a load candidate")
	}

	// Capped to 150 GB via memory_limit_gb: registration still says 256, but
	// the provider's own load gate will refuse, so the planner must not push.
	setMemory(150)
	if _, ok := reg.modelLoadCandidatePendingLocked(p, model, now); ok {
		t.Error("planner must not plan a 200 GB-minimum model onto a 150 GB-capped box")
	}
}
