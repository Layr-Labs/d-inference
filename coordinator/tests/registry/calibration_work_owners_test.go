package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCalibratedFirstContentFallsBackUntilModelLoadTransitionEnds(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, pr := f.provider, f.request
	before := f.evaluate(pr, now).Estimate
	if before.Status != forecast.Feasible || before.PredictionSource != "qualified_calibration" {
		t.Fatalf("idle model did not qualify before load: %+v", before)
	}
	// A competing model load can start before its weights appear in Slots.
	loading := true
	p.BackendCapacity.LoadTransitionActive = &loading
	f.posture.Activity(now)
	during := f.evaluate(pr, now).Estimate
	e := f.evidence(pr, now)
	if e.Calibration.WorkKnown || during.PredictionSource != "" ||
		!e.Workload.WholeMacBusy || during.Status != forecast.Unknown ||
		during.Reason != "competing_work_unknown" || during.ConservativeMs < 3330 ||
		during.BudgetMs != before.BudgetMs {
		t.Fatalf("load transition borrowed idle calibration or changed deadline: %+v", during)
	}
	loading = false
	if got := f.evaluate(pr, now.Add(time.Second)).Estimate; got.PredictionSource != "" {
		t.Fatalf("load completion bypassed cooldown: %+v", got)
	}
	ready := now.Add(20 * time.Second)
	p.CapacityAcceptedAt = ready
	// A new arrival gets its own clock; the earlier deadline is not extended.
	next := &production.PendingRequest{Model: pr.Model, EstimatedPromptTokens: pr.EstimatedPromptTokens,
		FirstContentPromptTokens: pr.FirstContentPromptTokens, RequestedMaxTokens: pr.RequestedMaxTokens,
		PromptWork: pr.PromptWork, FirstContentDeadline: ready.Add(4 * time.Second)}
	after := f.evaluate(next, ready).Estimate
	if !f.evidence(next, ready).Calibration.WorkKnown || after.PredictionSource != "qualified_calibration" ||
		after.ConservativeMs != before.ConservativeMs || after.BudgetMs != before.BudgetMs {
		t.Fatalf("cooled transition did not restore qualified evidence: %+v vs %+v", after, before)
	}
	assertCalibratedRootBinding(t)
}

func TestCalibratedWorkCorrelatesPendingAndRetiringOwners(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, pr := f.provider, f.request
	pending := &production.PendingRequest{RequestID: "existing", Model: "model", RequestedMaxTokens: 1000, PromptWork: pr.PromptWork}
	p.AddPending(pending)
	owner := deadline.PendingWork{Model: pending.Model, RequestedMaxTokens: pending.RequestedMaxTokens, PromptWork: pending.PromptWork, ServiceCharge: .0625}
	builder, known := deadline.BoundSlots(f.catalog, f.identity(), pr.Model)
	known = known && builder.Pending(owner, 0)
	work := builder.Finish()
	if !known || work.PrefillTokens != 4000 || work.DecodeTokens != 1000 || work.ContextTokens != 5000 {
		t.Fatalf("unreported pending work missing: %+v", work)
	}
	slot := &p.BackendCapacity.Slots[0]
	slot.NumRunning = 1
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true, PrefillTokens: 4000, DecodeTokens: 1000, RequestCount: 1, ContextTokensMax: 5000, ServiceFraction: .0625}
	*p.BackendCapacity.WholeMacServiceUsed = .0625
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: pending.ServiceReservationID(), UsedFraction: .0625}}
	builder, known = deadline.BoundSlots(f.catalog, f.identity(), pr.Model)
	known = known && builder.Pending(owner, p.BackendCapacity.WholeMacServiceReservations[0].UsedFraction)
	work = builder.Finish()
	if !known || work.ActiveRequests != 1 || work.PrefillTokens != 4000 {
		t.Fatalf("correlated owner double charged: %+v", work)
	}
	p.RemovePending(pending.RequestID)
	builder, known = deadline.BoundSlots(f.catalog, f.identity(), pr.Model)
	if !known || !builder.Retiring(.0625, p.BackendCapacity.WholeMacServiceReservations[0].UsedFraction) {
		t.Fatal("reported retiring work lost its bound")
	}
	p.BackendCapacity.WholeMacServiceReservations = nil
	builder, known = deadline.BoundSlots(f.catalog, f.identity(), pr.Model)
	if known && builder.Retiring(.0625, 0) {
		t.Fatal("unseen retirement inferred finished from receipt time")
	}
	assertCalibratedRootBinding(t)
}

func TestCalibratedWorkRejectsMissingLocalAndMaintenanceOwners(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Provider)
	}{
		{"unrepresented local service", func(p *production.Provider) { *p.BackendCapacity.WholeMacServiceUsed = .1 }},
		{"unrepresented execution", func(p *production.Provider) { p.BackendCapacity.Slots[0].NumRunning = 1 }},
		{"unrepresented queued prompt", func(p *production.Provider) { *p.BackendCapacity.Slots[0].Telemetry.QueuedPrefillTokens = 1 }},
		{"unrepresented eval", func(p *production.Provider) { p.BackendCapacity.Slots[0].EvalInFlightMs = 1 }},
		{"cache maintenance", func(p *production.Provider) { p.BackendCapacity.Slots[0].IdleClearInFlightMs = 1 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			tc.change(f.provider)
			if _, known := deadline.BoundSlots(f.catalog, f.identity(), f.request.Model); known {
				t.Fatal("unbounded work qualified")
			}
		})
	}
	assertCalibratedRootBinding(t)
}
