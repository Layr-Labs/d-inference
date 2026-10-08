package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

func TestWarmTargetDemandAndQueueSensitive(t *testing.T) {
	reg := newWarmRegistry(t)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	c := warmFixtureFor(reg).runtime
	params := c.TargetParams()
	now := time.Now()

	for _, model := range []string{gemmaBuild, qwenBuild} {
		t.Run(model, func(t *testing.T) {
			for _, tc := range []struct {
				name     string
				pressure warmplan.Pressure
				queue    warmplan.QueuePressure
				running  int
				waiting  int
				want     int
			}{
				{name: "idle", want: 2},
				{name: "capacity_reject", pressure: warmplan.Pressure{CapacityRejects: 1}, want: 3},
				{name: "young_queue", queue: warmplan.QueuePressure{Depth: 4, OldestAge: time.Second}, want: 2},
				{name: "aged_queue", queue: warmplan.QueuePressure{Depth: 4, OldestAge: 3 * time.Second}, want: 4},
				{name: "served_and_queued", running: 3, waiting: 1, queue: warmplan.QueuePressure{Depth: 1, OldestAge: 3 * time.Second}, want: 5},
				{name: "reachable_limit", queue: warmplan.QueuePressure{Depth: 20, OldestAge: 3 * time.Second}, want: 6},
			} {
				t.Run(tc.name, func(t *testing.T) {
					fleet := warmplan.Fleet{
						Model: model, Warm: 2, QualityConc: 1,
						Running: tc.running, Waiting: tc.waiting,
						EligibleCold: []warmplan.Candidate{
							{ProviderID: "c1"}, {ProviderID: "c2"}, {ProviderID: "c3"}, {ProviderID: "c4"},
						},
					}
					if got := c.TargetWarm(fleet, tc.pressure, tc.queue, params, time.Second, now); got != tc.want {
						t.Fatalf("warm target = %d, want %d", got, tc.want)
					}
				})
			}
		})
	}
}
