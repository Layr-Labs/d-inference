package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestFirstContentDormantSlotDoesNotBlockQualifiedDispatch(t *testing.T) {
	for _, mode := range []string{"primary", "hedge", "after_capacity_refusals"} {
		t.Run(mode, func(t *testing.T) {
			r := New(testLogger())
			p := makeSchedulerProvider(t, r, "provider", "warm-model", 100)
			setFreshIdleFirstContentTelemetry(p, 2000)
			p.mu.Lock()
			cutoff := p.CapacityAcceptedAt.Add(-time.Millisecond)
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots,
				protocol.BackendSlotCapacity{Model: "evicted-model", State: "idle_shutdown"})
			p.mu.Unlock()
			pr := &PendingRequest{RequestID: mode, Model: "warm-model", EstimatedPromptTokens: 1000,
				RequestedMaxTokens: 128, FirstContentDeadline: time.Now().Add(10 * time.Second)}
			switch mode {
			case "hedge":
				pr.Hedge = true
			case "after_capacity_refusals":
				pr.RequireFreshFeasible, pr.RequireFreshFeasibleAfter = true, cutoff
			}
			selected, decision := r.ReserveProviderEx(pr.Model, pr)
			if selected != p || decision.FirstContent.Status != FirstContentFeasible || decision.FirstContent.ServiceMs != 0 {
				t.Fatalf("dormant slot blocked qualified dispatch: selected=%v forecast=%+v", selected != nil, decision.FirstContent)
			}
		})
	}
}

func TestFirstContentOtherSlotUncertaintyStillBlocksQualification(t *testing.T) {
	one := int64(1)
	for _, tc := range []struct {
		name    string
		slot    protocol.BackendSlotCapacity
		pending bool
	}{
		{name: "crashed", slot: protocol.BackendSlotCapacity{State: "crashed"}},
		{name: "reloading", slot: protocol.BackendSlotCapacity{State: "reloading"}},
		{name: "loading", slot: protocol.BackendSlotCapacity{State: "loading"}},
		{name: "unknown", slot: protocol.BackendSlotCapacity{State: "unknown"}},
		{name: "omitted_state"},
		{name: "loaded_missing_telemetry", slot: protocol.BackendSlotCapacity{State: "idle"}},
		{name: "dormant_running", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", NumRunning: 1}},
		{name: "dormant_waiting", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", NumWaiting: 1}},
		{name: "dormant_eval", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", EvalInFlightMs: 1}},
		{name: "dormant_clear", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", IdleClearInFlightMs: 1}},
		{name: "dormant_wedge", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", WedgeSuspected: true}},
		// A single populated work field must override dormant state, even when
		// its companion is missing and overall workload telemetry is unknown.
		{name: "dormant_queued_prefill", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", Telemetry: &protocol.SlotTelemetry{QueuedPrefillTokens: &one}}},
		{name: "dormant_partial_prefill", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", Telemetry: &protocol.SlotTelemetry{PartialPrefillRows: &one}}},
		{name: "dormant_local_reservation", slot: protocol.BackendSlotCapacity{State: "idle_shutdown"}, pending: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			p := makeSchedulerProvider(t, r, "provider", "warm-model", 100)
			setFreshIdleFirstContentTelemetry(p, 2000)
			p.mu.Lock()
			tc.slot.Model = "other-model"
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, tc.slot)
			p.mu.Unlock()
			if tc.pending {
				p.AddPending(&PendingRequest{RequestID: "local", Model: tc.slot.Model, EstimatedPromptTokens: 500, RequestedMaxTokens: 128})
			}
			now := time.Now()
			c := &routingCandidate{}
			r.mu.RLock()
			p.mu.Lock()
			r.fillRoutingSnapshotPLocked(&c.snapshot, p, "warm-model", now)
			p.mu.Unlock()
			r.mu.RUnlock()
			pr := &PendingRequest{EstimatedPromptTokens: 1000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(10 * time.Second)}
			r.estimateFirstContent(c, pr, now)
			if c.firstContent.Status != FirstContentUnknown || c.firstContent.Reason != "competing_work_unknown" {
				t.Fatalf("uncertain work became qualified: %+v", c.firstContent)
			}
			pr.Hedge = true
			if firstContentCandidateAllowed(c, pr) {
				t.Fatal("hedge consumed uncertain capacity")
			}
			pr.Hedge, pr.RequireFreshFeasible = false, true
			if firstContentCandidateAllowed(c, pr) {
				t.Fatal("retry after capacity refusals accepted uncertain capacity")
			}
			if tc.pending && (c.snapshot.otherModelOccupancy != 1 || c.firstContent.ServiceMs <= 0) {
				t.Fatalf("dormant model reservation disappeared: occupancy=%d service=%v", c.snapshot.otherModelOccupancy, c.firstContent.ServiceMs)
			}
		})
	}
}

func TestFirstContentDormantTargetStillNeedsLoadEvidence(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "provider", "model", 100)
	setFreshIdleFirstContentTelemetry(p, 2000)
	now := time.Now()
	c := &routingCandidate{}
	r.mu.RLock()
	p.mu.Lock()
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	r.fillRoutingSnapshotPLocked(&c.snapshot, p, "model", now)
	p.mu.Unlock()
	r.mu.RUnlock()
	pr := &PendingRequest{EstimatedPromptTokens: 1000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(time.Minute)}
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != FirstContentUnknown || c.firstContent.Reason != "load_work_unknown" {
		t.Fatalf("dormant target skipped its load uncertainty: %+v", c.firstContent)
	}
}
