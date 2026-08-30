package registry

import "testing"

func TestOccupancyDeadlinePreferenceKeepsFitsAndUnknowns(t *testing.T) {
	withTTFTConfig(t, 50, defaultTTFTDeadlineBaseMs, TTFTAdmissionEnforce)

	busyMiss := &routingCandidate{snapshot: routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          55,
		prefillTPS:         660,
		backendRunning:     6,
	}}
	idleFit := &routingCandidate{snapshot: routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          4,
		prefillTPS:         2_000,
	}}
	unknown := &routingCandidate{snapshot: routingSnapshot{}}
	pr := &PendingRequest{
		EstimatedPromptTokens: 1_000,
		MaxTTFTMs:             10_000,
	}

	got := preferOccupancyDeadlineCandidates(
		[]*routingCandidate{busyMiss, idleFit, unknown}, pr)
	if len(got) != 2 || got[0] != idleFit || got[1] != unknown {
		t.Fatalf("preferred candidates = %v, want fitting+unknown candidates", got)
	}
}

func TestOccupancyDeadlinePreferenceAllMissKeepsBestChance(t *testing.T) {
	withTTFTConfig(t, 50, defaultTTFTDeadlineBaseMs, TTFTAdmissionEnforce)

	better := &routingCandidate{snapshot: routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          40,
		prefillTPS:         800,
		backendRunning:     1,
	}}
	worse := &routingCandidate{snapshot: routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          20,
		prefillTPS:         400,
		backendRunning:     4,
	}}
	pr := &PendingRequest{
		EstimatedPromptTokens: 1_000,
		MaxTTFTMs:             100,
	}

	got := preferOccupancyDeadlineCandidates(
		[]*routingCandidate{worse, better}, pr)
	if len(got) != 1 || got[0] != better {
		t.Fatalf("all-miss preference selected %+v, want minimum predicted TTFT", got)
	}
}

func TestOccupancyDeadlinePreferenceIsFailOpen(t *testing.T) {
	withTTFTConfig(t, 50, defaultTTFTDeadlineBaseMs, TTFTAdmissionEnforce)

	candidates := []*routingCandidate{
		{snapshot: routingSnapshot{}},
		{snapshot: routingSnapshot{}},
	}
	pr := &PendingRequest{
		EstimatedPromptTokens: 1_000,
		MaxTTFTMs:             1_000,
	}
	if got := preferOccupancyDeadlineCandidates(candidates, pr); len(got) != len(candidates) {
		t.Fatalf("unknown predictions narrowed pool to %d, want %d", len(got), len(candidates))
	}

	pr.RequiresVision = true
	known := []*routingCandidate{
		{snapshot: routingSnapshot{hasBackendCapacity: true, slotState: "running", decodeTPS: 20, prefillTPS: 200}},
		{snapshot: routingSnapshot{hasBackendCapacity: true, slotState: "running", decodeTPS: 40, prefillTPS: 400}},
	}
	if got := preferOccupancyDeadlineCandidates(known, pr); len(got) != len(known) {
		t.Fatalf("vision request narrowed pool to %d, want %d", len(got), len(known))
	}
}

func TestTTFTAdmissionEnforceRedirectsKnownMissWithoutRejecting(t *testing.T) {
	withTTFTConfig(t, 50, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	model := "ttft-enforce-routing-model"

	buildFleet := func() (*Registry, *Provider, *Provider) {
		reg := New(testLogger())
		fastBusy := makeSchedulerProvider(t, reg, "fast-busy", model, 55)
		fastBusy.mu.Lock()
		fastBusy.PrefillTPS = 660
		fastBusy.BackendCapacity.Slots[0].NumRunning = 6
		fastBusy.mu.Unlock()

		slowIdle := makeSchedulerProvider(t, reg, "slow-idle", model, 4)
		slowIdle.mu.Lock()
		slowIdle.PrefillTPS = 2_000
		slowIdle.mu.Unlock()
		return reg, fastBusy, slowIdle
	}
	request := func(id string) *PendingRequest {
		return &PendingRequest{
			RequestID:             id,
			Model:                 model,
			EstimatedPromptTokens: 1_000,
			RequestedMaxTokens:    256,
			MaxTTFTMs:             10_000,
		}
	}

	shadowRegistry, fastBusy, _ := buildFleet()
	selected, decision := shadowRegistry.ReserveProviderEx(model, request("shadow"))
	if selected == nil || selected.ID != fastBusy.ID {
		t.Fatalf("shadow selected %v, want completion-cheaper busy provider; decision=%+v", selected, decision)
	}

	SetTTFTAdmissionMode(TTFTAdmissionEnforce)
	enforceRegistry, _, slowIdle := buildFleet()
	selected, decision = enforceRegistry.ReserveProviderEx(model, request("enforce"))
	if selected == nil || selected.ID != slowIdle.ID {
		t.Fatalf("enforce selected %v, want known deadline-fitting idle provider; decision=%+v", selected, decision)
	}
	if decision.TTFTRejections != 0 {
		t.Fatalf("enforce created %d TTFT rejections, want fail-open preference only", decision.TTFTRejections)
	}
}
