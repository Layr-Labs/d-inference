package registry_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotConsentAloneDoesNotChangeServing(t *testing.T) {
	r, _, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	state := r.states[p.ID]
	p.ModelAutopilot.Active = false
	if state.RoutingBlocked(p.ModelAutopilot, p.ID, autopilotTestTarget, p.BackendCapacity, time.Now) || state.LegacyChangesBlocked(p.ModelAutopilot, p.ID, time.Now) {
		t.Fatal("consent without activation changed serving")
	}
	p.ModelAutopilot.Active = true
	state.AcceptControl(p.ModelAutopilot, protocol.ModelAutopilotControl{Revision: "test", ExpiresAtMS: now.Add(-time.Second).UnixMilli()})
	if state.Managed(p.ModelAutopilot, p.ID, time.Now()) {
		t.Fatal("expired lease retained managed ownership")
	}
	state.AcceptControl(p.ModelAutopilot, protocol.ModelAutopilotControl{Revision: "test", ExpiresAtMS: now.Add(time.Minute).UnixMilli()})
	p.ModelAutopilot.Revision = "changed"
	if state.Managed(p.ModelAutopilot, p.ID, time.Now()) {
		t.Fatal("old session activated a changed selection")
	}
}

func TestAutopilotPauseStopsReservationsAndPreservesPending(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	action := autopilotControllerPlan(t, r, c, now)
	command, ok := c.Reserve(action, now)
	if !ok {
		t.Fatal("reserve")
	}
	r.SetAutopilotPaused(true)
	if _, ok := c.Reserve(action, now); ok {
		t.Fatal("paused controller issued new operation")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	delivery, pending := r.states[p.ID].PrepareDelivery()
	if !pending || delivery.Command.CommandID != command.CommandID {
		t.Fatal("pause discarded in-flight ownership")
	}
}

func TestAutopilotSnapshotKeepsLoadMeasurementAfterUnload(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	p.Mu().Lock()
	p.Models[0].WeightHash = "verified"
	p.ModelAutopilot.LoadHistory = []protocol.ModelAutopilotLoadTiming{{ModelID: autopilotTestTarget, WeightHash: "verified", LoadMS: 2700, MeasuredAtMS: now.Add(-time.Minute).UnixMilli()}}
	p.Mu().Unlock()
	fit := c.Fleet(now).Nodes[0].Fits[autopilotTestTarget]
	if fit.LoadSeconds != 2.7 {
		t.Fatalf("load history not used: %+v", fit)
	}
	p.Mu().Lock()
	p.ModelAutopilot.LoadHistory[0].WeightHash = "other-build"
	p.Mu().Unlock()
	fit = c.Fleet(now).Nodes[0].Fits[autopilotTestTarget]
	if fit.LoadSeconds != r.cfg.LoadTimePrior.Seconds() {
		t.Fatal("measurement from different bytes reused")
	}
}

func TestAutopilotPreservesConfiguredFloorsWhenWarmPoolDisabled(t *testing.T) {
	r, control := newAutopilotFixture(autopilot.DefaultConfig())
	cfg := testWarmPoolConfig()
	cfg.Enabled = false
	cfg.MinWarmByModel = map[string]int{"protected": 2}
	stop := r.StartWarmPoolController(context.Background(), cfg)
	defer stop()
	if err := r.ConfigureAutopilot(autopilot.DefaultConfig()); err != nil {
		t.Fatal(err)
	}
	f := (*control).Fleet(time.Now())
	if f.Floors["protected"] != 2 {
		t.Fatalf("configured floor lost: %+v", f.Floors)
	}
	if r.RequestWarmPoolTrigger() || len(r.TriggerWarmPool()) != 0 {
		t.Fatal("disabled warm pool issued work")
	}
}

func TestAutopilotUsesResolvedAccountDeadlineWithoutAccountIdentity(t *testing.T) {
	r, _, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	concurrency := p.MaxConcurrencyForModel(autopilotTestTarget)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	entry := production.CatalogEntry{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16}
	evidence := autopilotcontrol.FitEvidence{
		Model: entry.ID, SoloTPS: 100, PrefillTPS: p.PrefillTPS, MaxConcurrency: concurrency,
		DecodeFloorTPS: 15, LoadFactor: effectiveTPSLoadFactor, Metrics: p.SystemMetrics,
		SuccessfulJobs: p.Reputation.SuccessfulJobs, TotalJobs: p.Reputation.TotalJobs,
		ResponseTime: p.Reputation.AvgResponseTime, Slots: p.BackendCapacity.Slots,
	}
	limits := func() autopilotcontrol.FitLimits {
		return autopilotcontrol.FitLimits{
			HardwareFits:    admission.ModelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)),
			ColdTokenBudget: memorypolicy.ColdTokenBudgetWithOffload(float64(p.Hardware.MemoryGB), entry.SizeGB, 0, 0, entry.ID),
		}
	}
	d := autopilot.DemandView{Requests: 10, PromptTokens: 1024, TailPromptTokens: 1024, RequestedMaxTokens: 64, DeadlineKnown: true, DeadlineSeconds: .001}
	if autopilotcontrol.ModelFit(evidence, d, r.cfg, limits).MeetsDeadline {
		t.Fatal("tight resolved SLA ignored")
	}
	d.DeadlineSeconds = 0
	if !autopilotcontrol.ModelFit(evidence, d, r.cfg, limits).MeetsDeadline {
		t.Fatal("deadline invented for exempt requests")
	}
	sample := autopilot.DemandSample{Model: "model", PromptTokens: 100, RequestedMaxTokens: 64, DeadlineKnown: true}
	exempt := autopilot.ShapeKey(sample)
	sample.FirstContentDeadline = 5 * time.Second
	if exempt == autopilot.ShapeKey(sample) {
		t.Fatal("SLA and exempt requests share a cohort")
	}
	tracker := autopilot.DemandTracker{}
	sample.ReceivedAt = now.Add(-time.Second)
	tracker.Record(sample, now, 5*time.Minute)
	sample.FirstContentDeadline = 0
	tracker.Record(sample, now, 5*time.Minute)
	views := tracker.ShapeSnapshot(now, 5*time.Minute)
	if !views[exempt].DeadlineKnown || views[exempt].DeadlineSeconds != 0 {
		t.Fatal("exempt deadline lost during aggregation")
	}
	sample.FirstContentDeadline = 5 * time.Second
	if views[autopilot.ShapeKey(sample)].DeadlineSeconds != 5 {
		t.Fatal("SLA budget lost during aggregation")
	}
}
