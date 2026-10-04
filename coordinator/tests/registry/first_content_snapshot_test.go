package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
	"time"
)

func TestFirstContentDormantSlotDoesNotBlockQualifiedDispatch(t *testing.T) {
	for _, mode := range []string{"primary", "hedge", "after_capacity_refusals"} {
		t.Run(mode, func(t *testing.T) {
			f := newObservedForecastFixture(t, "provider", "warm-model", 100)
			r, p := f.r, f.p
			f.fresh(2000)
			p.Mu().Lock()
			cutoff := p.CapacityAcceptedAt.Add(-time.Millisecond)
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{Model: "evicted-model", State: "idle_shutdown"})
			p.Mu().Unlock()
			pr := &production.PendingRequest{RequestID: mode, Model: "warm-model", EstimatedPromptTokens: 1000,
				RequestedMaxTokens: 128, FirstContentDeadline: time.Now().Add(10 * time.Second)}
			switch mode {
			case "hedge":
				pr.Hedge = true
			case "after_capacity_refusals":
				pr.RequireFreshFeasible, pr.RequireFreshFeasibleAfter = true, cutoff
			}
			selected, decision := r.ReserveProviderEx(pr.Model, pr)
			if selected != p || decision.FirstContent.Status != production.FirstContentFeasible || decision.FirstContent.ServiceMs != 0 {
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
		{name: "dormant_queued_prefill", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", Telemetry: &protocol.SlotTelemetry{QueuedPrefillTokens: &one}}},
		{name: "dormant_partial_prefill", slot: protocol.BackendSlotCapacity{State: "idle_shutdown", Telemetry: &protocol.SlotTelemetry{PartialPrefillRows: &one}}},
		{name: "dormant_local_reservation", slot: protocol.BackendSlotCapacity{State: "idle_shutdown"}, pending: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newObservedForecastFixture(t, "provider", "warm-model", 100)
			p := f.p
			f.fresh(2000)
			p.Mu().Lock()
			tc.slot.Model = "other-model"
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, tc.slot)
			p.Mu().Unlock()
			var pending []forecast.PendingWork
			if tc.pending {
				p.AddPending(&production.PendingRequest{RequestID: "local", Model: tc.slot.Model, EstimatedPromptTokens: 500, RequestedMaxTokens: 128})
				pending = append(pending, forecast.PendingWork{Model: tc.slot.Model, EstimatedPromptTokens: 500, RequestedMaxTokens: 128})
			}
			now := time.Now()
			p.Mu().Lock()
			e := f.evidence(now, pending...)
			p.Mu().Unlock()
			pr := forecast.Request{PromptTokens: 1000, UpperBoundTokens: 1000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: now.Add(10 * time.Second)}
			estimate := forecast.Evaluate(e, pr, now).Estimate
			if estimate.Status != forecast.Unknown || estimate.Reason != "competing_work_unknown" {
				t.Fatalf("uncertain work became qualified: %+v", estimate)
			}
			pr.Hedge = true
			if forecast.Allows(estimate, pr, e.Workload.WholeMacBusy) {
				t.Fatal("hedge consumed uncertain capacity")
			}
			pr.Hedge, pr.RequireFreshFeasible = false, true
			if forecast.Allows(estimate, pr, e.Workload.WholeMacBusy) {
				t.Fatal("retry after capacity refusals accepted uncertain capacity")
			}
			if tc.pending && (e.Workload.OtherModelOccupancy != 1 || estimate.ServiceMs <= 0) {
				t.Fatalf("dormant model reservation disappeared: occupancy=%d service=%v", e.Workload.OtherModelOccupancy, estimate.ServiceMs)
			}
		})
	}
}

func TestFirstContentDormantTargetStillNeedsLoadEvidence(t *testing.T) {
	f := newObservedForecastFixture(t, "provider", "model", 100)
	f.fresh(2000)
	now := time.Now()
	f.p.Mu().Lock()
	f.p.BackendCapacity.Slots[0].State = "idle_shutdown"
	e := f.evidence(now)
	f.p.Mu().Unlock()
	pr := forecast.Request{PromptTokens: 1000, UpperBoundTokens: 1000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: now.Add(time.Minute)}
	estimate := forecast.Evaluate(e, pr, now).Estimate
	if estimate.Status != forecast.Unknown || estimate.Reason != "load_work_unknown" {
		t.Fatalf("dormant target skipped its load uncertainty: %+v", estimate)
	}
}
