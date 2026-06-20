package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// An idle provider that has the model on disk (serving a DIFFERENT model) is a
// valid cold-load target.
func TestColdSpillProvidersDetectsIdleOnDiskProvider(t *testing.T) {
	reg := New(testLogger())
	model := "cold-spill-model"
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 1 {
		t.Fatalf("ColdSpillProviders = %d, want 1", n)
	}
}

// When a warm provider already serves the model, it is the normal warm path, not
// a cold-spill case.
func TestColdSpillProvidersZeroWhenWarmProviderExists(t *testing.T) {
	reg := New(testLogger())
	model := "cold-spill-warm"
	makeSchedulerProvider(t, reg, "warm", model, 80)           // model "running" (warm)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8) // model on disk

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 0 {
		t.Fatalf("ColdSpillProviders = %d, want 0 (warm provider present)", n)
	}
}

// A provider with in-flight work cannot evict its active model, so it is not a
// cold-load target (mirrors bestModelLoadProviderLocked).
func TestColdSpillProvidersZeroWhenBusy(t *testing.T) {
	reg := New(testLogger())
	model := "cold-spill-busy"
	cold := makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cold.AddPending(&PendingRequest{RequestID: "inflight"})

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 0 {
		t.Fatalf("ColdSpillProviders = %d, want 0 (provider busy)", n)
	}
}

// A model that cannot physically fit the provider is never a cold-load target.
func TestColdSpillProvidersZeroWhenModelTooLarge(t *testing.T) {
	reg := New(testLogger())
	model := "cold-spill-toobig"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 128, SizeGB: 100}})
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8) // only 64 GB

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 0 {
		t.Fatalf("ColdSpillProviders = %d, want 0 (model too large)", n)
	}
}

// Allowed-serial filtering excludes providers whose serial is not in the set.
func TestColdSpillProvidersHonorsAllowedSerials(t *testing.T) {
	reg := New(testLogger())
	model := "cold-spill-serial"
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false, "serial-no-provider-has"); n != 0 {
		t.Fatalf("ColdSpillProviders(allowed=nonexistent) = %d, want 0", n)
	}
}

// A provider already in the middle of a pending model load is skipped — a second
// load_model would oscillate single-slot machines, and TriggerModelSwaps would
// skip it anyway.
func TestColdSpillProvidersZeroWhenLoadPending(t *testing.T) {
	reg := New(testLogger())
	model := "cold-spill-pending-load"
	cold := makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)

	// Reserve a pending load for this provider/model, as TriggerModelSwaps would.
	reg.reservePendingModelLoads([]modelLoadAction{{providerID: cold.ID, modelID: model}}, time.Now())

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 0 {
		t.Fatalf("ColdSpillProviders = %d, want 0 (load already pending)", n)
	}
}

func TestColdSpillProvidersDetectsIdleReassignableProvider(t *testing.T) {
	reg := New(testLogger())
	assigned := "cold-spill-assigned"
	unassigned := "cold-spill-unassigned"
	p := makeSchedulerProvider(t, reg, "cold-wrong-pool", assigned, 80)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: unassigned, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity = nil
	p.WarmModels = nil
	p.CurrentModel = ""
	p.mu.Unlock()

	if n := reg.ColdSpillProviders(unassigned, RequestTraits{}, false); n != 1 {
		t.Fatalf("ColdSpillProviders = %d, want 1 for idle reassignable provider", n)
	}
}

func TestColdSpillProvidersZeroForResidentUnassignedModelPool(t *testing.T) {
	reg := New(testLogger())
	assigned := "cold-spill-resident-assigned"
	unassigned := "cold-spill-resident-unassigned"
	p := makeSchedulerProvider(t, reg, "cold-resident-wrong-pool", assigned, 80)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: unassigned, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: assigned, State: "idle"}}
	p.mu.Unlock()

	if n := reg.ColdSpillProviders(unassigned, RequestTraits{}, false); n != 0 {
		t.Fatalf("ColdSpillProviders = %d, want 0 for resident wrong-pool provider", n)
	}
	if got := reg.PoolRejectedProviderCount(unassigned, RequestTraits{}, false); got != 1 {
		t.Fatalf("PoolRejectedProviderCount = %d, want 1", got)
	}
}
