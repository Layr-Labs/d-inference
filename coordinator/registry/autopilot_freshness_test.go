package registry

import (
	"testing"
	"time"
)

func TestAutopilotSlowControlCadenceHasBoundedDeliveryGrace(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	c.config.Interval = time.Minute
	p := autopilotControllerProvider(t, r, "controlled", now, autopilotTestDonor)
	for _, tc := range []struct {
		age  time.Duration
		warm int
	}{{65 * time.Second, 1}, {71 * time.Second, 0}} {
		p.mu.Lock()
		p.capacitySamplesAt = now.Add(-tc.age)
		p.mu.Unlock()
		if got := autopilotCoverage(r.autopilotFleetSnapshot(c, now)).Warm[autopilotTestDonor]; got != tc.warm {
			t.Fatalf("age=%v warm=%d want=%d", tc.age, got, tc.warm)
		}
	}
}

func TestAutopilotSlowOrdinaryHeartbeatRetainsDonorCapacity(t *testing.T) {
	for _, mode := range []string{"ordinary", "waiting", "shadow", "paused", "expired control", "active control"} {
		t.Run(mode, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "donor", now, autopilotTestDonor)
			p.mu.Lock()
			p.capacitySamplesAt = now.Add(-45 * time.Second)
			p.LastHeartbeat = p.capacitySamplesAt
			switch mode {
			case "ordinary":
				p.ModelAutopilot = nil
			case "waiting":
				p.ModelAutopilot.Active = false
			case "shadow":
				p.ModelAutopilot.Active = false
				p.ModelAutopilot.ObserveOnly = true
				p.autopilotControlObserveOnly = true
			case "paused":
				p.ModelAutopilot.Active = false
				p.ModelAutopilot.Paused = true
			case "expired control":
				p.autopilotControlUntil = now.Add(-time.Second)
			}
			p.mu.Unlock()
			coverage := autopilotCoverage(r.autopilotFleetSnapshot(c, now))
			wantWarm := 1
			if mode == "active control" {
				wantWarm = 0 // Active renewals must keep the stricter 30s budget.
			}
			if coverage.Warm[autopilotTestDonor] != wantWarm {
				t.Fatalf("warm donor credit=%d want=%d", coverage.Warm[autopilotTestDonor], wantWarm)
			}

			// A liveness-only/rejected heartbeat cannot revive old capacity.
			p.mu.Lock()
			p.capacitySamplesAt = now.Add(-DefaultProviderHeartbeatTimeout - time.Second)
			p.LastHeartbeat = now
			p.mu.Unlock()
			if autopilotCoverage(r.autopilotFleetSnapshot(c, now)).Warm[autopilotTestDonor] != 0 {
				t.Fatal("expired capacity gained donor credit from connection liveness alone")
			}
		})
	}
}
