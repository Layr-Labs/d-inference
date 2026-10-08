package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotLiveDonorsRequireActualServingPermission(t *testing.T) {
	for _, mode := range []string{"shadow", "selected waiting", "selected expired", "selected rebound"} {
		t.Run(mode, func(t *testing.T) {
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = false
			r, c, now := newAutopilotControllerTestConfig(t, cfg)
			r.selectLiveMachines(t, 0)
			if mode != "shadow" {
				r.selectLiveMachines(t, 1, 2)
			}
			warm := testWarmPoolConfig()
			warm.MinWarmByModel = map[string]int{autopilotTestTarget: 1, autopilotTestDonor: 1}
			r.ConfigureWarmPool(warm)
			live := autopilotMachineProvider(t, r, "live", r.machineID(t, 0), now, autopilotTestDonor)
			peer := autopilotMachineProvider(t, r, "peer", r.machineID(t, 1), now, autopilotTestDonor)
			live.Mu().Lock()
			live.ModelAutopilot.MaxModelSlots = 1
			live.Mu().Unlock()
			action := autopilotControllerPlan(t, r, c, now)
			peer.Mu().Lock()
			peer.Models[1].WeightHash = "cached-donor-weights"
			r.states[peer.ID].RegisterInventory(peer.Models[:1], peer.Models[1:], peer.ModelAutopilot)
			peer.ModelAutopilot.MaxModelSlots = 1
			switch mode {
			case "selected waiting":
				peer.ModelAutopilot.Active = false
			case "selected expired":
				r.states[peer.ID].AcceptControl(peer.ModelAutopilot, protocol.ModelAutopilotControl{Enabled: true, Revision: "test", ExpiresAtMS: now.Add(-time.Second).UnixMilli()})
			}
			peer.Mu().Unlock()
			if mode == "selected rebound" && !r.BindVerifiedMachineIdentity(peer, peer.AccountID, r.machineID(t, 2)) {
				t.Fatal("rebind rejected")
			}
			fleet := c.Fleet(now)
			if coverage := autopilot.Coverage(fleet.Fleet); coverage.Warm[autopilotTestDonor] != 1 {
				t.Fatalf("observer-only resident became an actual donor: %+v", coverage)
			}
			if plan := autopilotcontrol.Plan(fleet, cfg, now); plan != nil {
				t.Fatalf("hypothetical permission let live plan spend the last actual donor: %+v", plan)
			}
			if _, ok := c.Reserve(action, now); ok {
				t.Fatal("final reservation trusted hypothetical observer-only donor capacity")
			}
			if mode == "shadow" {
				shadowCfg := cfg
				shadowCfg.ObserveOnly = true
				if plan := autopilotcontrol.Plan(fleet, shadowCfg, now); plan == nil || plan.Node.ID != peer.ID {
					t.Fatal("actual-donor fence removed the separate inert shadow proposal")
				}
			}
		})
	}
}

func TestAutopilotActualShadowDonorRetainsMixedInventoryPermission(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	r, c, now := newAutopilotControllerTestConfig(t, cfg)
	r.selectLiveMachines(t, 0)
	p := autopilotMachineProvider(t, r, "shadow", r.machineID(t, 1), now, autopilotTestDonor)
	p.Mu().Lock()
	p.Models[0].WeightHash = "cached-target-weights"
	r.states[p.ID].RegisterInventory(p.Models[1:], p.Models[:1], p.ModelAutopilot)
	p.Mu().Unlock()
	fleet := c.Fleet(now)
	if autopilot.Coverage(fleet.Fleet).Warm[autopilotTestDonor] != 1 {
		t.Fatal("hypothetical expanded permissions hid a real ordinary donor")
	}
	shadowCfg := cfg
	shadowCfg.ObserveOnly = true
	if action := autopilotcontrol.Plan(fleet, shadowCfg, now); action == nil || action.Node.ID != p.ID || action.Load != autopilotTestTarget || len(action.Unload) != 0 {
		t.Fatalf("shadow proposal should add a cached target without losing its donor: %+v", action)
	}
}
