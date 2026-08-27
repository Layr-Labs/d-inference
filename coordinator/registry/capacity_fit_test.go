package registry

import (
	"fmt"
	"testing"
)

func TestStructuralFitWeightedRendezvousPreservesSpread(t *testing.T) {
	t.Parallel()

	candidate := func(id string, capacity int64, known bool, memoryGB float64) *routingCandidate {
		provider := &Provider{ID: id}
		return &routingCandidate{
			provider:          provider,
			snapshot:          routingSnapshot{provider: provider, totalMemoryGB: memoryGB},
			fitCapacityTokens: capacity,
			fitKnown:          known,
		}
	}

	assertBoundedBias := func(name string, candidates []*routingCandidate, preferredID string) {
		t.Helper()
		counts := map[string]int{}
		const requests = 2_000
		for i := 0; i < requests; i++ {
			selected := selectCandidateByStructuralFit(
				candidates, fmt.Sprintf("%s-%d", name, i))
			counts[selected.provider.ID]++
		}
		share := float64(counts[preferredID]) / requests
		if share < 0.58 || share > 0.72 {
			t.Fatalf("%s preferred share = %.3f, want bounded ~2:1 bias; counts=%v", name, share, counts)
		}
		for _, candidate := range candidates {
			if counts[candidate.provider.ID] == 0 {
				t.Fatalf("%s starved candidate %q; counts=%v", name, candidate.provider.ID, counts)
			}
		}
	}

	assertBoundedBias("known-budget", []*routingCandidate{
		candidate("roomy", 131_072, true, 128),
		candidate("tight", 8_192, true, 32),
	}, "tight")
	assertBoundedBias("unknown-budget", []*routingCandidate{
		candidate("large-ram", 0, false, 128),
		candidate("small-ram", 0, false, 32),
	}, "small-ram")

	// Mixed reporting is uniform: knowledge itself cannot become an advantage.
	mixed := []*routingCandidate{
		candidate("known", 8_192, true, 32),
		candidate("legacy", 0, false, 128),
	}
	counts := map[string]int{}
	for i := 0; i < 2_000; i++ {
		selected := selectCandidateByStructuralFit(mixed, fmt.Sprintf("mixed-%d", i))
		counts[selected.provider.ID]++
	}
	knownShare := float64(counts["known"]) / 2_000
	if knownShare < 0.42 || knownShare > 0.58 {
		t.Fatalf("mixed-knowledge share = %.3f, want neutral split; counts=%v", knownShare, counts)
	}
}

func TestStructuralFitCannotOverrideLatencyOrLoad(t *testing.T) {
	t.Parallel()

	tight := &routingCandidate{
		costMs:            nearTieCostWindowMs + 1,
		effectiveQueue:    0,
		fitKnown:          true,
		fitCapacityTokens: 1,
	}
	fastRoomy := &routingCandidate{
		costMs:            0,
		effectiveQueue:    0,
		fitKnown:          true,
		fitCapacityTokens: 100_000,
	}
	if got := selectRoutingCandidate(
		[]*routingCandidate{tight, fastRoomy},
		func(candidate *routingCandidate) float64 { return candidate.costMs },
		"latency",
	); got != fastRoomy {
		t.Fatal("structural fit crossed the bounded latency window")
	}

	idleRoomy := &routingCandidate{
		costMs:            100,
		effectiveQueue:    0,
		fitKnown:          true,
		fitCapacityTokens: 100_000,
	}
	busyTight := &routingCandidate{
		costMs:            100,
		effectiveQueue:    1,
		fitKnown:          true,
		fitCapacityTokens: 1,
	}
	if got := selectRoutingCandidate(
		[]*routingCandidate{busyTight, idleRoomy},
		func(candidate *routingCandidate) float64 { return candidate.costMs },
		"load",
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

	counts := map[int]int{}
	const shortRequests = 300
	for i := 0; i < shortRequests; i++ {
		requestID := fmt.Sprintf("short-%d", i)
		selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
			RequestID:             requestID,
			Model:                 model,
			EstimatedPromptTokens: 512,
			RequestedMaxTokens:    256,
		})
		if selected == nil {
			t.Fatalf("short request %d was not routed: %+v", i, decision)
		}
		selected.mu.Lock()
		selectedMemory := selected.Hardware.MemoryGB
		selected.mu.Unlock()
		counts[selectedMemory]++
		if decision.CandidateCount != 2*providersPerClass {
			t.Fatalf("short request candidate count = %d, want %d", decision.CandidateCount, 2*providersPerClass)
		}
		selected.RemovePending(requestID)
		reg.SetProviderIdle(selected.ID)
	}
	tightShare := float64(counts[32]) / shortRequests
	if tightShare < 0.55 || tightShare > 0.78 || counts[128] == 0 {
		t.Fatalf("short-request size-class split = %v (tight share %.3f), want bounded preference without starvation", counts, tightShare)
	}

	long := &PendingRequest{
		RequestID:             "long",
		Model:                 model,
		EstimatedPromptTokens: 32_000,
		RequestedMaxTokens:    4_096,
	}
	selected, decision := reg.ReserveProviderEx(model, long)
	if selected == nil {
		t.Fatalf("long request was not routed: %+v", decision)
	}
	selected.mu.Lock()
	selectedMemory := selected.Hardware.MemoryGB
	selected.mu.Unlock()
	if selectedMemory != 128 {
		t.Fatalf("long request selected %d GB provider, want 128 GB class", selectedMemory)
	}
	if decision.CapacityRejections < providersPerClass {
		t.Fatalf("long request capacity rejections = %d, want at least %d tight providers", decision.CapacityRejections, providersPerClass)
	}
}
