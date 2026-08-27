package registry

import (
	"fmt"
	"testing"
)

func TestNarrowCandidatesByStructuralFit(t *testing.T) {
	t.Parallel()

	tight := &routingCandidate{fitKnown: true, fitSlackTokens: 2_000}
	roomy := &routingCandidate{fitKnown: true, fitSlackTokens: 60_000}
	if got := narrowCandidatesByStructuralFit([]*routingCandidate{roomy, tight}); len(got) != 1 || got[0] != tight {
		t.Fatalf("known structural fit selected %+v, want tight candidate", got)
	}

	smallRAM := &routingCandidate{snapshot: routingSnapshot{totalMemoryGB: 32}}
	largeRAM := &routingCandidate{snapshot: routingSnapshot{totalMemoryGB: 128}}
	if got := narrowCandidatesByStructuralFit([]*routingCandidate{largeRAM, smallRAM}); len(got) != 1 || got[0] != smallRAM {
		t.Fatalf("unknown-budget RAM fit selected %+v, want 32 GB candidate", got)
	}

	// Mixed reporting must not turn "known" into an advantage over a legacy
	// provider whose structural ceiling is simply unavailable.
	if got := narrowCandidatesByStructuralFit([]*routingCandidate{tight, largeRAM}); len(got) != 2 {
		t.Fatalf("mixed budget knowledge narrowed to %d candidates, want neutral set of 2", len(got))
	}
}

func TestStructuralFitCannotOverrideLatencyOrLoad(t *testing.T) {
	t.Parallel()

	tight := &routingCandidate{
		costMs:         nearTieCostWindowMs + 1,
		effectiveQueue: 0,
		fitKnown:       true,
		fitSlackTokens: 1,
	}
	fastRoomy := &routingCandidate{
		costMs:         0,
		effectiveQueue: 0,
		fitKnown:       true,
		fitSlackTokens: 100_000,
	}
	if got := selectRoutingCandidate(
		[]*routingCandidate{tight, fastRoomy},
		func(candidate *routingCandidate) float64 { return candidate.costMs },
	); got != fastRoomy {
		t.Fatal("structural fit crossed the bounded latency window")
	}

	idleRoomy := &routingCandidate{
		costMs:         100,
		effectiveQueue: 0,
		fitKnown:       true,
		fitSlackTokens: 100_000,
	}
	busyTight := &routingCandidate{
		costMs:         100,
		effectiveQueue: 1,
		fitKnown:       true,
		fitSlackTokens: 1,
	}
	if got := selectRoutingCandidate(
		[]*routingCandidate{busyTight, idleRoomy},
		func(candidate *routingCandidate) float64 { return candidate.costMs },
	); got != idleRoomy {
		t.Fatal("structural fit overrode the lower-occupancy candidate")
	}
}

func TestReserveProviderExFleetScaleUsesStructuralSizeClasses(t *testing.T) {
	reg := New(testLogger())
	model := "fleet-size-class-model"

	const providersPerClass = 500
	for i := 0; i < providersPerClass; i++ {
		tight := makeTokenBudgetProvider(
			t, reg, fmt.Sprintf("tight-%04d", i), model, 50, 0, 8_192, 0)
		tight.mu.Lock()
		tight.Hardware.MemoryGB = 32
		tight.BackendCapacity.TotalMemoryGB = 32
		tight.mu.Unlock()

		roomy := makeTokenBudgetProvider(
			t, reg, fmt.Sprintf("roomy-%04d", i), model, 50, 0, 131_072, 0)
		roomy.mu.Lock()
		roomy.Hardware.MemoryGB = 128
		roomy.BackendCapacity.TotalMemoryGB = 128
		roomy.mu.Unlock()
	}

	short := &PendingRequest{
		RequestID:             "short",
		Model:                 model,
		EstimatedPromptTokens: 512,
		RequestedMaxTokens:    256,
	}
	selected, decision := reg.ReserveProviderEx(model, short)
	if selected == nil {
		t.Fatalf("short request was not routed: %+v", decision)
	}
	selected.mu.Lock()
	selectedMemory := selected.Hardware.MemoryGB
	selected.mu.Unlock()
	if selectedMemory != 32 {
		t.Fatalf("short request selected %d GB provider, want constrained 32 GB class", selectedMemory)
	}
	if decision.CandidateCount != 2*providersPerClass {
		t.Fatalf("short request candidate count = %d, want %d", decision.CandidateCount, 2*providersPerClass)
	}

	long := &PendingRequest{
		RequestID:             "long",
		Model:                 model,
		EstimatedPromptTokens: 32_000,
		RequestedMaxTokens:    4_096,
	}
	selected, decision = reg.ReserveProviderEx(model, long)
	if selected == nil {
		t.Fatalf("long request was not routed: %+v", decision)
	}
	selected.mu.Lock()
	selectedMemory = selected.Hardware.MemoryGB
	selected.mu.Unlock()
	if selectedMemory != 128 {
		t.Fatalf("long request selected %d GB provider, want 128 GB class", selectedMemory)
	}
	if decision.CapacityRejections < providersPerClass {
		t.Fatalf("long request capacity rejections = %d, want at least %d tight providers", decision.CapacityRejections, providersPerClass)
	}
}
