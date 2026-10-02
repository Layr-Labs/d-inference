package registry

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotConsentAloneDoesNotChangeServing(t *testing.T) {
	r, _, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.ModelAutopilot.Active = false
	if providerAutopilotRoutingBlockedLocked(p, autopilotTestTarget) || providerLegacyModelChangesBlockedLocked(p) {
		t.Fatal("consent without activation changed serving")
	}
	p.ModelAutopilot.Active = true
	p.autopilotControlUntil = now.Add(-time.Second)
	if providerAutopilotManagedLocked(p) {
		t.Fatal("expired lease retained managed ownership")
	}
	p.autopilotControlUntil = now.Add(time.Minute)
	p.ModelAutopilot.Revision = "changed"
	if providerAutopilotManagedLocked(p) {
		t.Fatal("old session activated a changed selection")
	}
}

func TestAutopilotPauseStopsReservationsAndPreservesPending(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	action := autopilotControllerPlan(t, r, c, now)
	command, ok := r.reserveAutopilotAction(c, action, now)
	if !ok {
		t.Fatal("reserve")
	}
	r.SetAutopilotPaused(true)
	if _, ok := r.reserveAutopilotAction(c, action, now); ok {
		t.Fatal("paused controller issued new operation")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.autopilotPending == nil || p.autopilotPending.Command.CommandID != command.CommandID {
		t.Fatal("pause discarded in-flight ownership")
	}
}

func TestAutopilotSnapshotKeepsLoadMeasurementAfterUnload(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Models[0].WeightHash = "verified"
	p.ModelAutopilot.LoadHistory = []protocol.ModelAutopilotLoadTiming{{ModelID: autopilotTestTarget, WeightHash: "verified", LoadMS: 2700, MeasuredAtMS: now.Add(-time.Minute).UnixMilli()}}
	fit := r.autopilotModelFitLocked(p, autopilotTestTarget, autopilot.DemandView{}, c.config)
	if fit.LoadSeconds != 2.7 {
		t.Fatalf("load history not used: %+v", fit)
	}
	p.ModelAutopilot.LoadHistory[0].WeightHash = "other-build"
	fit = r.autopilotModelFitLocked(p, autopilotTestTarget, autopilot.DemandView{}, c.config)
	if fit.LoadSeconds != c.config.LoadTimePrior.Seconds() {
		t.Fatal("measurement from different bytes reused")
	}
}

func TestAutopilotPreservesConfiguredFloorsWhenWarmPoolDisabled(t *testing.T) {
	r := New(testLogger())
	cfg := testWarmPoolConfig()
	cfg.Enabled = false
	cfg.MinWarmByModel = map[string]int{"protected": 2}
	stop := r.StartWarmPoolController(context.Background(), cfg)
	defer stop()
	if err := r.ConfigureAutopilot(autopilot.DefaultConfig()); err != nil {
		t.Fatal(err)
	}
	f := r.autopilotFleetSnapshot(r.autopilot, time.Now())
	if f.Floors["protected"] != 2 {
		t.Fatalf("configured floor lost: %+v", f.Floors)
	}
	if r.RequestWarmPoolTrigger() || len(r.TriggerWarmPool()) != 0 {
		t.Fatal("disabled warm pool issued work")
	}
}

func TestAutopilotUsesResolvedAccountDeadlineWithoutAccountIdentity(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "provider", now)
	p.mu.Lock()
	defer p.mu.Unlock()
	d := autopilot.DemandView{Requests: 10, PromptTokens: 1024, TailPromptTokens: 1024, RequestedMaxTokens: 64, DeadlineKnown: true, DeadlineSeconds: .001}
	if r.autopilotModelFitLocked(p, autopilotTestTarget, d, c.config).MeetsDeadline {
		t.Fatal("tight resolved SLA ignored")
	}
	d.DeadlineSeconds = 0
	if !r.autopilotModelFitLocked(p, autopilotTestTarget, d, c.config).MeetsDeadline {
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
