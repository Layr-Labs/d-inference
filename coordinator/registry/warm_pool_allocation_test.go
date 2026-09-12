package registry

import (
	"fmt"
	"testing"
	"time"
)

func TestWarmPoolAllocationReplacesLostReservations(t *testing.T) {
	candidates := []warmPoolCandidate{{providerID: "lost-a"}, {providerID: "a"}, {providerID: "lost-b"}, {providerID: "b"}}
	visited := make(map[string]int)
	reserve := func(batch []modelLoadAction, _ time.Time) []modelLoadAction {
		out := batch[:0]
		for _, action := range batch {
			visited[action.providerID]++
			if action.providerID == "a" || action.providerID == "b" {
				out = append(out, action)
			}
		}
		return out
	}
	actions := allocateWarmPoolLoads("demand", candidates, 2, make(map[string]struct{}), reserve, time.Now())
	if len(actions) != 2 || actions[0].providerID != "a" || actions[1].providerID != "b" {
		t.Fatalf("lost reservations stranded eligible alternatives: %+v", actions)
	}
	for id, count := range visited {
		if count != 1 {
			t.Fatalf("candidate %s revisited %d times", id, count)
		}
	}
}

func TestWarmPoolAllocationExhaustionIsBounded(t *testing.T) {
	visits := 0
	candidates := []warmPoolCandidate{{providerID: "a"}, {providerID: "b"}, {providerID: "c"}}
	actions := allocateWarmPoolLoads("demand", candidates, 2, make(map[string]struct{}),
		func(batch []modelLoadAction, _ time.Time) []modelLoadAction { visits += len(batch); return nil }, time.Now())
	if len(actions) != 0 || visits != len(candidates) {
		t.Fatalf("actions=%v visits=%d; want one bounded pass", actions, visits)
	}
}

// Both models have the same ranked cold machines. The first consumes the two
// best machines; the second must use the next two within the SAME tick, rather
// than reserve the already-claimed pair and leave its warm deficit unchanged.
func TestWarmPoolSharedColdFleetFillsBothModels(t *testing.T) {
	for _, observe := range []bool{false, true} {
		t.Run(fmt.Sprintf("observe=%t", observe), func(t *testing.T) {
			r := New(testLogger())
			models := []string{"demand-a", "demand-b"}
			for _, model := range models {
				warm := makeSchedulerProvider(t, r, "warm-"+model, model, 20)
				warm.BackendCapacity.Slots[0].NumRunning = 3
			}
			for i := 0; i < 4; i++ {
				provider := makeWarmPoolColdProvider(t, r, fmt.Sprintf("cold-%d", i), models[0], 20, 64, float64(8+i))
				provider.Models = append(provider.Models, r.GetProvider("warm-" + models[1]).Models[0])
			}
			cfg := testWarmPoolConfig()
			cfg.ObserveOnly = observe
			cfg.DecodeFloorTPS = 15
			cfg.MaxLoadsPerTick = 2
			cfg.MaxLoadsPerTickCeiling = 4
			cfg.RampGapFraction = 1
			cfg.MaxGlobalPendingLoads = 4
			r.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(r)
			for _, model := range models {
				r.RecordWarmPoolCapacityReject(model)
			}
			snapshots := r.warmPool.tick(time.Now())
			claimed := make(map[string]bool)
			for _, snapshot := range snapshots {
				if len(snapshot.Actions) != 2 {
					t.Fatalf("model %s planned %d loads, want 2: %+v", snapshot.Model, len(snapshot.Actions), snapshot)
				}
				for _, action := range snapshot.Actions {
					if claimed[action.providerID] {
						t.Fatalf("two models claimed provider %s", action.providerID)
					}
					claimed[action.providerID] = true
				}
			}
			if len(claimed) != 4 || (!observe && len(*sent) != 4) || (observe && len(*sent) != 0) {
				t.Fatalf("claimed=%d sent=%d observe=%v", len(claimed), len(*sent), observe)
			}
		})
	}
}
