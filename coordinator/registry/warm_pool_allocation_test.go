package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestWarmPoolAllocationUsesAlternateCandidates(t *testing.T) {
	for _, observe := range []bool{false, true} {
		t.Run(fmt.Sprint(observe), func(t *testing.T) {
			r := New(testLogger())
			for i := 0; i < 4; i++ {
				p := makeWarmPoolColdProvider(t, r, fmt.Sprint(i), "a", 80, 64, 8)
				p.mu.Lock()
				p.Models = append(p.Models, protocol.ModelInfo{ID: "b"})
				p.mu.Unlock()
			}
			cfg := testWarmPoolConfig()
			cfg.ObserveOnly, cfg.MaxLoadsPerTick = observe, 4
			cfg.MinWarmByModel = map[string]int{"a": 2, "b": 2}
			r.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(r)
			snaps := r.warmPool.tick(time.Now())
			seen := map[string]bool{}
			for _, snap := range snaps {
				if len(snap.Actions) != 2 {
					t.Fatalf("model %s got %d loads, want 2", snap.Model, len(snap.Actions))
				}
				for _, a := range snap.Actions {
					if seen[a.providerID] {
						t.Fatal("provider assigned twice")
					}
					seen[a.providerID] = true
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
	r := New(testLogger())
	p := makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
	r.ConfigureWarmPool(testWarmPoolConfig())
	p.BackendCapacity.Slots[0].NumRunning = 1
	if got := r.warmPool.reserveActions([]modelLoadAction{{providerID: "p", modelID: "m"}}, time.Now()); len(got) != 0 {
		t.Fatal("reserved model load after provider became busy")
	}
	if got := r.warmPool.reserveActions([]modelLoadAction{{providerID: "disconnected", modelID: "m"}}, time.Now()); len(got) != 0 {
		t.Fatal("reserved disconnected provider")
	}
}

func TestActiveWarmPoolOwnsModelSwapTriggers(t *testing.T) {
	r := New(testLogger())
	r.ConfigureWarmPool(testWarmPoolConfig())
	r.TriggerModelSwaps()
	if len(r.warmPool.triggerC) != 1 {
		t.Fatal("swap bypassed active controller")
	}
	r.TriggerModelSwaps()
	if len(r.warmPool.triggerC) != 1 {
		t.Fatal("full trigger must remain coalesced")
	}
}

func TestWarmPoolPlacementDwellExpires(t *testing.T) {
	r := New(testLogger())
	p := makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MinDwell = time.Minute
	r.ConfigureWarmPool(cfg)
	now := time.Now()
	p.lastWarmPlacementAt = now
	_, reason := r.warmPoolCandidateReasonLocked(p, "m", now.Add(time.Second))
	if reason != warmColdDwell {
		t.Fatalf("got %q, want dwell", reason)
	}
	_, reason = r.warmPoolCandidateReasonLocked(p, "m", now.Add(time.Minute))
	if reason != warmColdEligible {
		t.Fatalf("expired dwell still blocked: %q", reason)
	}
}

func TestWarmPoolSuccessfulLoadDwellSurvivesHeartbeatOrdering(t *testing.T) {
	for _, heartbeatFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("heartbeat_first_%t", heartbeatFirst), func(t *testing.T) {
			r := New(testLogger())
			const loaded, next = "loaded-model", "next-model"
			p := makeWarmPoolColdProvider(t, r, "p", loaded, 80, 64, 8)
			p.Models = append(p.Models, protocol.ModelInfo{ID: next})
			cfg := testWarmPoolConfig()
			cfg.MinDwell = time.Minute
			r.ConfigureWarmPool(cfg)
			previousPlacement := time.Now().Add(-2 * cfg.MinDwell)
			p.lastWarmPlacementAt = previousPlacement
			key := modelLoadKey{ProviderID: p.ID, ModelID: loaded}
			r.pendingModelLoads[key] = time.Now().Add(time.Minute)
			r.pendingModelLoadStarted[key] = time.Now()
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
				if p.lastWarmPlacementAt != previousPlacement {
					t.Fatal("heartbeat alone changed placement dwell")
				}
			}
			beforeSuccess := time.Now()
			r.MarkModelWarm(p.ID, loaded)
			r.ClearPendingModelLoad(p.ID, loaded)
			if !heartbeatFirst && !r.Heartbeat(p.ID, heartbeat) {
				t.Fatal("load completion heartbeat rejected")
			}
			placedAt := p.lastWarmPlacementAt
			if placedAt.Before(beforeSuccess) {
				t.Fatal("successful load did not refresh placement dwell")
			}
			if len(p.WarmModels) != 1 || p.WarmModels[0] != loaded {
				t.Fatalf("warm models = %v, want one loaded model", p.WarmModels)
			}
			_, reason := r.warmPoolCandidateReasonLocked(p, next, placedAt.Add(cfg.MinDwell/2))
			if reason != warmColdDwell {
				t.Fatalf("newly placed provider selected for another model: %q", reason)
			}
			_, reason = r.warmPoolCandidateReasonLocked(p, next, placedAt.Add(cfg.MinDwell))
			if reason != warmColdEligible {
				t.Fatalf("placement dwell did not expire: %q", reason)
			}
		})
	}
}

func TestWarmPoolPreservesRecentResidencyWithoutStarvingNewModel(t *testing.T) {
	r := New(testLogger())
	valuable := makeWarmPoolColdProvider(t, r, "valuable", "m", 80, 128, 8)
	spare := makeWarmPoolColdProvider(t, r, "spare", "m", 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MinDwell = time.Minute
	r.ConfigureWarmPool(cfg)
	now := time.Now()
	valuable.warmWorkCounters = map[string]warmWorkCounters{"other": {lastWorkAt: now}}
	fleet := r.warmPoolFleetSnapshot(now)["m"]
	if len(fleet.eligibleCold) != 2 || fleet.eligibleCold[0].providerID != spare.ID {
		t.Fatalf("recent useful residency not preserved: %+v", fleet.eligibleCold)
	}
	r.Disconnect(spare.ID)
	fleet = r.warmPoolFleetSnapshot(now)["m"]
	if len(fleet.eligibleCold) != 1 || fleet.eligibleCold[0].providerID != valuable.ID {
		t.Fatal("residency preference starved new model without alternatives")
	}
}
