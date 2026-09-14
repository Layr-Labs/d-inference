package registry

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

func TestWarmPoolPublishesSnapshotBeforeReentrantSend(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-publication"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	reg.ConfigureWarmPool(cfg)
	reg.RecordWarmPoolCapacityReject(model)
	var observedErr error
	var sent int
	reg.loadModelSender = func(providerID, modelID string) error {
		sent++
		snaps, at := reg.LatestWarmPoolSnapshots()
		if len(snaps) != 1 || snaps[0].Model != model || len(snaps[0].Actions) != 1 || at.IsZero() {
			observedErr = fmt.Errorf("snapshot before send = %+v at %v", snaps, at)
			return observedErr
		}
		data, err := json.Marshal(snaps[0])
		if err != nil {
			observedErr = err
			return err
		}
		var wire struct{ Actions []map[string]any }
		if err := json.Unmarshal(data, &wire); err != nil {
			observedErr = err
			return err
		}
		if len(wire.Actions) != 1 || len(wire.Actions[0]) != 0 {
			observedErr = fmt.Errorf("snapshot exposed private action fields: %s", data)
			return observedErr
		}
		originalTarget := snaps[0].TargetWarm
		snaps[0].TargetWarm = -1
		latest, _ := reg.LatestWarmPoolSnapshots()
		if latest[0].TargetWarm != originalTarget {
			observedErr = fmt.Errorf("caller changed stored snapshot target: %d", latest[0].TargetWarm)
			return observedErr
		}
		reg.RecordWarmPoolLoadResult(modelID, true, time.Second)
		reg.ConfigureWarmPool(cfg)
		reg.ClearPendingModelLoad(providerID, modelID)
		return nil
	}
	done := make(chan []WarmPoolSnapshot, 1)
	go func() { done <- reg.TriggerWarmPool() }()
	select {
	case snaps := <-done:
		if observedErr != nil {
			t.Fatal(observedErr)
		}
		if sent != 1 || len(snaps) != 1 || len(snaps[0].Actions) != 1 {
			t.Fatalf("sent=%d snapshots=%+v, want one reserved action", sent, snaps)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("warm-pool send could not reenter snapshot, pressure, configuration and command cleanup")
	}
}
