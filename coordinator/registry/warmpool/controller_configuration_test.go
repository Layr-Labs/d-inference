package warmpool

import (
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

func TestControllerTickKeepsOneConfigurationThroughSend(t *testing.T) {
	for _, observeOnly := range []bool{false, true} {
		name := "active_to_observe"
		if observeOnly {
			name = "observe_to_active"
		}
		t.Run(name, func(t *testing.T) {
			cfg := Config{Enabled: true, ObserveOnly: observeOnly, Interval: time.Second, MaxLoadsPerTick: 1, MaxGlobalPendingLoads: 1, MinWarmByModel: map[string]int{"model": 1}, FallbackQualityConcurrency: 1}
			entered := make(chan struct{})
			resume := make(chan struct{})
			done := make(chan struct{})
			result := make(chan []Snapshot[string], 1)
			release := sync.OnceFunc(func() { close(resume) })
			pause := sync.OnceFunc(func() { close(entered); <-resume })
			t.Cleanup(func() {
				release()
				select {
				case <-done:
				case <-time.After(2 * time.Second):
					t.Error("paused tick did not finish")
				}
			})
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			reserved, sent := 0, 0
			controller := NewController(cfg, Bindings[string]{
				FleetSnapshot: func(time.Time) map[string]FleetModel {
					return map[string]FleetModel{"model": {Model: "model", EligibleCold: []Candidate{{ProviderID: "cold"}}, ColdIneligible: 1}}
				},
				PendingCount:     func(time.Time) int { return 0 },
				Action:           func(providerID, modelID string) string { return providerID + ":" + modelID },
				IsDedicatedModel: func(string) bool { return false },
				Reserve: func(actions []string, _ time.Time) []string {
					reserved += len(actions)
					if !observeOnly {
						pause()
					}
					return actions
				},
				Send: func(actions []string) { sent += len(actions) },
				Logger: func() *slog.Logger {
					if observeOnly {
						pause()
					}
					return logger
				},
			})
			go func() { defer close(done); result <- controller.Tick(time.Now()) }()
			select {
			case <-entered:
			case <-time.After(2 * time.Second):
				t.Fatal("tick did not reach the reservation/publication boundary")
			}
			next := cfg
			next.ObserveOnly = !observeOnly
			controller.Configure(next)
			release()
			var snapshots []Snapshot[string]
			select {
			case snapshots = <-result:
			case <-time.After(2 * time.Second):
				t.Fatal("configured tick did not finish")
			}
			if len(snapshots) != 1 || len(snapshots[0].Actions) != 1 || snapshots[0].ObserveOnly != observeOnly {
				t.Fatalf("in-flight snapshot changed configuration: %+v", snapshots)
			}
			want := 1
			if observeOnly {
				want = 0
			}
			if reserved != want || sent != want {
				t.Fatalf("in-flight reserved=%d sent=%d, want both %d", reserved, sent, want)
			}
			snapshots = controller.Tick(time.Now().Add(time.Second))
			if len(snapshots) != 1 || snapshots[0].ObserveOnly != next.ObserveOnly {
				t.Fatalf("next tick did not use published configuration: %+v", snapshots)
			}
			if reserved != 1 || sent != 1 {
				t.Fatalf("two passes reserved=%d sent=%d, want both 1", reserved, sent)
			}
		})
	}
}
