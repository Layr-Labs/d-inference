package warmpool

import (
	"testing"
	"time"
)

func TestControllerConfigureDoesNotWaitForInFlightTick(t *testing.T) {
	entered := make(chan struct{})
	resume := make(chan struct{})
	tickDone := make(chan struct{})
	controller := NewController(Config{MaxLoadsPerTick: 1, MaxGlobalPendingLoads: 1, Interval: time.Second}, Bindings[string]{
		FleetSnapshot: func(time.Time) map[string]FleetModel { close(entered); <-resume; return nil },
		PendingCount:  func(time.Time) int { return 0 },
	})
	go func() { controller.Tick(time.Now()); close(tickDone) }()
	<-entered
	configured := make(chan struct{})
	go func() {
		controller.Configure(Config{Enabled: true, ObserveOnly: true, Interval: time.Second})
		close(configured)
	}()
	select {
	case <-configured:
		if !controller.Enabled() || !controller.ObserveOnly() {
			t.Fatal("configuration publication was not visible")
		}
	case <-time.After(2 * time.Second):
		close(resume)
		t.Fatal("configuration waited on the in-flight tick")
	}
	close(resume)
	select {
	case <-tickDone:
	case <-time.After(2 * time.Second):
		t.Fatal("tick did not finish after fleet observation resumed")
	}
}
