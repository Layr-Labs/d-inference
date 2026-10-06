package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestActiveWarmPoolOwnsModelSwapTriggers(t *testing.T) {
	r := newWarmRegistry(t)
	r.ConfigureWarmPool(testWarmPoolConfig())
	r.TriggerModelSwaps()
	if len(warmFixtureFor(r).deps.Wakeups) != 1 {
		t.Fatal("swap bypassed active controller")
	}
	r.TriggerModelSwaps()
	if len(warmFixtureFor(r).deps.Wakeups) != 1 {
		t.Fatal("full trigger must remain coalesced")
	}
}

func TestWarmPoolAllocationUsesAlternateCandidates(t *testing.T) {
	for _, observe := range []bool{false, true} {
		t.Run(fmt.Sprint(observe), func(t *testing.T) {
			r := newWarmRegistry(t)
			for i := 0; i < 4; i++ {
				p := makeWarmPoolColdProvider(t, r, fmt.Sprint(i), "a", 80, 64, 8)
				p.Mu().Lock()
				p.Models = append(p.Models, protocol.ModelInfo{ID: "b"})
				p.Mu().Unlock()
			}
			cfg := testWarmPoolConfig()
			cfg.ObserveOnly, cfg.MaxLoadsPerTick = observe, 4
			cfg.MinWarmByModel = map[string]int{"a": 2, "b": 2}
			r.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(r)
			snaps := warmFixtureFor(r).runtime.Tick(time.Now())
			seen := map[string]bool{}
			for _, snap := range snaps {
				if len(snap.Actions) != 2 {
					t.Fatalf("model %s got %d loads, want 2", snap.Model, len(snap.Actions))
				}
				for _, a := range snap.Actions {
					if seen[a.ProviderID] {
						t.Fatal("provider assigned twice")
					}
					seen[a.ProviderID] = true
				}
			}
			if len(seen) != 4 {
				t.Fatalf("assigned %d, want 4", len(seen))
			}
			if observe && len(*sent) != 0 {
				t.Fatal("observe-only sent commands")
			}
		})
	}
}

func TestWarmPoolReservationRechecksProviderWork(t *testing.T) {
	r := newWarmRegistry(t)
	p := makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
	r.ConfigureWarmPool(testWarmPoolConfig())
	p.BackendCapacity.Slots[0].NumRunning = 1
	if got := warmFixtureFor(r).deps.Reserve([]production.ModelLoadAction{{ProviderID: "p", ModelID: "m"}}, time.Now()); len(got) != 0 {
		t.Fatal("reserved model load after provider became busy")
	}
	if got := warmFixtureFor(r).deps.Reserve([]production.ModelLoadAction{{ProviderID: "disconnected", ModelID: "m"}}, time.Now()); len(got) != 0 {
		t.Fatal("reserved disconnected provider")
	}
}

func TestWarmPoolPreservesRecentResidencyWithoutStarvingNewModel(t *testing.T) {
	r := newWarmRegistry(t)
	valuable := makeWarmPoolColdProvider(t, r, "valuable", "m", 80, 128, 8)
	spare := makeWarmPoolColdProvider(t, r, "spare", "m", 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MinDwell = time.Minute
	r.ConfigureWarmPool(cfg)
	now := time.Now()
	capacity := warmWorkCapacity("resident", 0, 0, 0, 0)
	capacity.Slots[0].Model = "other"
	warmFixtureFor(r).history(valuable.ID).Reconcile(capacity, now.Add(-time.Second), warmFixtureFor(r).deps.State, map[string]bool{"other": true}, 2*time.Minute)
	capacity = warmWorkCapacity("resident", 1, 1, 1, 1)
	capacity.Slots[0].Model = "other"
	warmFixtureFor(r).history(valuable.ID).Reconcile(capacity, now, warmFixtureFor(r).deps.State, map[string]bool{"other": true}, 2*time.Minute)
	fleet := warmFixtureFor(r).deps.Fleet(now)["m"]
	if len(fleet.EligibleCold) != 2 || fleet.EligibleCold[0].ProviderID != spare.ID {
		t.Fatalf("recent useful residency not preserved: %+v", fleet.EligibleCold)
	}
	r.Disconnect(spare.ID)
	fleet = warmFixtureFor(r).deps.Fleet(now)["m"]
	if len(fleet.EligibleCold) != 1 || fleet.EligibleCold[0].ProviderID != valuable.ID {
		t.Fatal("residency preference starved new model without alternatives")
	}
}

func TestWarmPoolPlacementDwellExpires(t *testing.T) {
	r := newWarmRegistry(t)
	p := makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MinDwell = time.Minute
	r.ConfigureWarmPool(cfg)
	now := time.Now()
	warmFixtureFor(r).lifecycle(p.ID).Place(now)
	reason := warmCandidateReason(r, "m", now.Add(time.Second))
	if reason != warmplan.WarmColdDwell {
		t.Fatalf("got %q, want dwell", reason)
	}
	reason = warmCandidateReason(r, "m", now.Add(time.Minute))
	if reason != warmplan.WarmColdEligible {
		t.Fatalf("expired dwell still blocked: %q", reason)
	}
}

func TestWarmPoolSuccessfulLoadDwellSurvivesHeartbeatOrdering(t *testing.T) {
	for _, heartbeatFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("heartbeat_first_%t", heartbeatFirst), func(t *testing.T) {
			r := newWarmRegistry(t)
			const loaded, next = "loaded-model", "next-model"
			p := makeWarmPoolColdProvider(t, r, "p", loaded, 80, 64, 8, next)
			cfg := testWarmPoolConfig()
			cfg.MinDwell = time.Minute
			r.ConfigureWarmPool(cfg)
			previousPlacement := time.Now().Add(-2 * cfg.MinDwell)
			warmFixtureFor(r).lifecycle(p.ID).Place(previousPlacement)
			warmFixtureFor(r).loads.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: loaded}}, time.Now())
			active := loaded
			heartbeat := &protocol.HeartbeatMessage{
				Status: "idle", ActiveModel: &active, WarmModels: []string{loaded},
				BackendCapacity: &protocol.BackendCapacity{
					CapacitySeq: 1, TotalMemoryGB: 64, GPUMemoryActiveGB: 8,
					Slots: []protocol.BackendSlotCapacity{{Model: loaded, State: "idle"}},
				},
			}
			if heartbeatFirst {
				if !r.Heartbeat(p.ID, heartbeat) {
					t.Fatal("load completion heartbeat rejected")
				}
				if warmFixtureFor(r).lifecycle(p.ID).placement() != previousPlacement {
					t.Fatal("heartbeat alone changed placement dwell")
				}
			}
			beforeSuccess := time.Now()
			r.MarkModelWarm(p.ID, loaded)
			r.ClearPendingModelLoad(p.ID, loaded)
			if !heartbeatFirst && !r.Heartbeat(p.ID, heartbeat) {
				t.Fatal("load completion heartbeat rejected")
			}
			placedAt := warmFixtureFor(r).lifecycle(p.ID).placement()
			if placedAt.Before(beforeSuccess) {
				t.Fatal("successful load did not refresh placement dwell")
			}
			if len(p.WarmModels) != 1 || p.WarmModels[0] != loaded {
				t.Fatalf("warm models = %v, want one loaded model", p.WarmModels)
			}
			reason := warmCandidateReason(r, next, placedAt.Add(cfg.MinDwell/2))
			if reason != warmplan.WarmColdDwell {
				t.Fatalf("newly placed provider selected for another model: %q", reason)
			}
			reason = warmCandidateReason(r, next, placedAt.Add(cfg.MinDwell))
			if reason != warmplan.WarmColdEligible {
				t.Fatalf("placement dwell did not expire: %q", reason)
			}
		})
	}
}
