package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tests for the MIN_WARM floor's ability to actually re-warm a box after the
// provider's 1h idle-unload (postmortem 2026-07-06 §3.3: floors were impotent
// because the controller clamps its target to warm + eligible_cold, and
// eligibility blocked every cold box — "eligible_cold: 0").

// warmSnapshotFor returns the snapshot row for model (tick emits one row per
// observed model).
func warmSnapshotFor(t *testing.T, snaps []WarmPoolSnapshot, model string) WarmPoolSnapshot {
	t.Helper()
	for _, s := range snaps {
		if s.Model == model {
			return s
		}
	}
	t.Fatalf("no warm-pool snapshot for model %q in %+v", model, snaps)
	return WarmPoolSnapshot{}
}

// TestWarmPoolMinWarmFloorRewarmsIdleUnloadedBox covers the floor path with the
// busy gate at its default 0 and a truly idle cold candidate: a warm box whose
// provider idle-unloads the model (its backend slot disappears) is re-warmed on
// the next tick because warm < MinWarmByModel — with ZERO demand pressure. The
// floor must act on eligibility alone.
func TestWarmPoolMinWarmFloorRewarmsIdleUnloadedBox(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-floor-rewarm"
	cfg := testWarmPoolConfig()
	cfg.MinWarmByModel = map[string]int{model: 1}
	p := makeSchedulerProvider(t, reg, "floor-box", model, 80)
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	// Warm and floor-satisfied: no loads issued.
	snaps := reg.warmPool.tick(time.Now())
	if len(*sent) != 0 {
		t.Fatalf("warm phase sent %d loads, want 0", len(*sent))
	}
	snap := warmSnapshotFor(t, snaps, model)
	if snap.WarmProviders != 1 || snap.TargetWarm != 1 {
		t.Fatalf("warm phase snapshot = warm %d target %d, want 1/1", snap.WarmProviders, snap.TargetWarm)
	}

	// Simulate the provider's idle-unload: the model's backend slot disappears
	// (the provider reports one slot per resident model), box now cold and idle.
	p.mu.Lock()
	p.BackendCapacity.Slots = nil
	p.mu.Unlock()

	snaps = reg.warmPool.tick(time.Now())
	snap = warmSnapshotFor(t, snaps, model)
	if snap.WarmProviders != 0 || snap.EligibleCold != 1 {
		t.Fatalf("cold phase snapshot = warm %d eligible_cold %d (disq %v), want 0/1 — eligibility wrongly blocks the re-warm",
			snap.WarmProviders, snap.EligibleCold, snap.ColdDisqualifiers)
	}
	if snap.TargetWarm != 1 {
		t.Fatalf("cold phase target = %d, want 1 (MIN_WARM floor with zero demand pressure)", snap.TargetWarm)
	}
	if len(*sent) != 1 || (*sent)[0].providerID != "floor-box" || (*sent)[0].modelID != model {
		t.Fatalf("cold phase loads = %+v, want exactly one re-warm of floor-box/%s", *sent, model)
	}
}

// TestWarmPoolMinWarmFloorRewarmsLightlyBusyBox is the busy-gate regression on
// the same floor path: the idle-unloaded box is still serving ONE request of
// another model. With the historical fully-idle gate (AllowBusyLoadMax=0) the
// floor is clamped to eligible_cold=0 and cannot act; with the bounded-busy
// gate at 2 the box is eligible and the floor re-warms it.
func TestWarmPoolMinWarmFloorRewarmsLightlyBusyBox(t *testing.T) {
	model := "warm-pool-floor-busy-rewarm"

	build := func(t *testing.T, allowBusyLoadMax int) (*Registry, *[]modelLoadAction) {
		reg := New(testLogger())
		cfg := testWarmPoolConfig()
		cfg.MinWarmByModel = map[string]int{model: 1}
		cfg.AllowBusyLoadMax = allowBusyLoadMax
		p := makeSchedulerProvider(t, reg, "busy-box", model, 80)
		p.mu.Lock()
		// Idle-unloaded `model`, still decoding one request of a co-resident model.
		p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
			{Model: "co-resident-model", State: "running", NumRunning: 1},
		}
		p.mu.Unlock()
		reg.ConfigureWarmPool(cfg)
		return reg, captureWarmPoolLoads(reg)
	}

	// Historical gate: the single in-flight request blocks eligibility, the
	// floor is clamped, no load is issued (this is the postmortem trap).
	reg, sent := build(t, 0)
	snaps := reg.warmPool.tick(time.Now())
	snap := warmSnapshotFor(t, snaps, model)
	if len(*sent) != 0 || snap.EligibleCold != 0 {
		t.Fatalf("allow_busy=0: loads %d eligible_cold %d, want 0/0 (historical behavior preserved)", len(*sent), snap.EligibleCold)
	}
	if snap.ColdDisqualifiers["not_idle"] != 1 {
		t.Fatalf("allow_busy=0: disqualifiers = %v, want not_idle:1 surfaced for the dashboard", snap.ColdDisqualifiers)
	}

	// Bounded-busy gate: the same box is eligible and the floor re-warms it.
	reg, sent = build(t, 2)
	snaps = reg.warmPool.tick(time.Now())
	snap = warmSnapshotFor(t, snaps, model)
	if snap.EligibleCold != 1 {
		t.Fatalf("allow_busy=2: eligible_cold = %d (disq %v), want 1", snap.EligibleCold, snap.ColdDisqualifiers)
	}
	if len(*sent) != 1 || (*sent)[0].providerID != "busy-box" || (*sent)[0].modelID != model {
		t.Fatalf("allow_busy=2: loads = %+v, want exactly one re-warm of busy-box/%s", *sent, model)
	}
}
