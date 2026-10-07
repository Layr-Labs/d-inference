package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotSlowControlCadenceHasBoundedDeliveryGrace(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.Enabled, cfg.ObserveOnly, cfg.Interval = true, false, time.Minute
	r, c, now := newAutopilotControllerTestConfig(t, cfg)
	p := autopilotControllerProvider(t, r, "controlled", now, autopilotTestDonor)
	for _, tc := range []struct {
		age  time.Duration
		warm int
	}{{65 * time.Second, 1}, {71 * time.Second, 0}} {
		p.Mu().Lock()
		r.samples[p.ID].MarkAccepted(now.Add(-tc.age))
		p.Mu().Unlock()
		if got := autopilot.Coverage(c.Fleet(now).Fleet).Warm[autopilotTestDonor]; got != tc.warm {
			t.Fatalf("age=%v warm=%d want=%d", tc.age, got, tc.warm)
		}
	}
}

func TestAutopilotSlowOrdinaryHeartbeatRetainsDonorCapacity(t *testing.T) {
	for _, mode := range []string{"ordinary", "waiting", "shadow", "paused", "expired control", "active control"} {
		t.Run(mode, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "donor", now, autopilotTestDonor)
			p.Mu().Lock()
			r.samples[p.ID].MarkAccepted(now.Add(-45 * time.Second))
			p.LastHeartbeat = now.Add(-45 * time.Second)
			switch mode {
			case "ordinary":
				p.ModelAutopilot = nil
			case "waiting":
				p.ModelAutopilot.Active = false
			case "shadow":
				p.ModelAutopilot.Active = false
				p.ModelAutopilot.ObserveOnly = true
				r.states[p.ID].AcceptControl(p.ModelAutopilot, protocol.ModelAutopilotControl{Revision: "test", ObserveOnly: true, ExpiresAtMS: now.Add(time.Hour).UnixMilli()})
			case "paused":
				p.ModelAutopilot.Active = false
				p.ModelAutopilot.Paused = true
			case "expired control":
				r.states[p.ID].AcceptControl(p.ModelAutopilot, protocol.ModelAutopilotControl{Revision: "test", ExpiresAtMS: now.Add(-time.Second).UnixMilli()})
			}
			p.Mu().Unlock()
			coverage := autopilot.Coverage(c.Fleet(now).Fleet)
			wantWarm := 1
			if mode == "active control" {
				wantWarm = 0 // Active renewals must keep the stricter 30s budget.
			}
			if coverage.Warm[autopilotTestDonor] != wantWarm {
				t.Fatalf("warm donor credit=%d want=%d", coverage.Warm[autopilotTestDonor], wantWarm)
			}
			// Liveness-only/rejected heartbeats cannot revive old capacity.
			p.Mu().Lock()
			r.samples[p.ID].MarkAccepted(now.Add(-production.DefaultProviderHeartbeatTimeout - time.Second))
			p.LastHeartbeat = now
			p.Mu().Unlock()
			if autopilot.Coverage(c.Fleet(now).Fleet).Warm[autopilotTestDonor] != 0 {
				t.Fatal("expired capacity gained donor credit from connection liveness alone")
			}
		})
	}
}
