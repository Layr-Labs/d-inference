package registry_test

import (
	"context"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotSelectedReconnectNeedsFreshBindingAndControlAcknowledgement(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	w := newWriterFixture(0, 8, nil, nil, nil, nil)
	t.Cleanup(func() { w.Close(); w.Run() })
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
		d.Connections = autopilotDeliveryWriters{"reconnected": w}
	})
	r.selectLiveMachines(t, 0)
	old := autopilotMachineProvider(t, r, "old-session", r.machineID(t, 0), now)
	oldAction := autopilotControllerPlan(t, r, c, now)
	r.Disconnect(old.ID)
	p := autopilotMachineProvider(t, r, "reconnected", "", now)
	c.RefreshControlLeases(now)
	if control := readAutopilotControl(t, w); !control.ObserveOnly {
		t.Fatalf("unverified reconnect inherited live membership: %+v", control)
	}
	if _, ok := c.Reserve(oldAction, now); ok {
		t.Fatal("previous session plan survived reconnect")
	}
	if !r.BindVerifiedMachineIdentity(p, p.AccountID, r.machineID(t, 0)) {
		t.Fatal("fresh machine continuity rejected")
	}
	c.RefreshControlLeases(now)
	control := readAutopilotControl(t, w)
	if control.ObserveOnly || !control.Enabled {
		t.Fatalf("selected verified reconnect did not receive live grant: %+v", control)
	}
	if plan := autopilotcontrol.Plan(c.Fleet(now), cfg, now); plan != nil {
		t.Fatal("selected machine became live before acknowledging its grant")
	}
	state := autopilotControllerState()
	state.SessionID = p.ID
	for _, seq := range []uint64{10, 0} {
		// Rejected sequence or unsequenced legacy report is not the live ack.
		r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(seq), ModelAutopilot: state})
		p.Mu().Lock()
		active := r.states[p.ID].ControlActive(p.ModelAutopilot, p.ID, time.Now())
		p.Mu().Unlock()
		if active {
			t.Fatalf("capacity sequence %d activated a new lease", seq)
		}
	}
	state.SessionID = old.ID
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: state})
	if autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
		t.Fatal("another session's acknowledgement activated control")
	}
	state.SessionID, state.Revision = p.ID, "old-selection"
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(12), ModelAutopilot: state})
	if autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
		t.Fatal("another revision's acknowledgement activated control")
	}
	state.Revision = control.Revision
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(13), ModelAutopilot: state})
	p.Mu().Lock()
	r.samples[p.ID].MarkAccepted(now)
	p.Mu().Unlock()
	action := autopilotControllerPlan(t, r, c, now)
	if action.Node.ID != p.ID || !action.Node.ControlActive || action.Node.ObserveOnly {
		t.Fatalf("fresh selected session did not gain live control: %+v", action.Node)
	}
	if _, ok := c.Reserve(action, now); !ok {
		t.Fatal("fresh verified reconnect with live acknowledgement could not reserve")
	}
}

func TestAutopilotQueuedLiveGrantCannotRestoreReboundAuthority(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	w := newWriterFixture(0, 8, nil, nil, nil, nil)
	t.Cleanup(func() { w.Close(); w.Run() })
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
		d.Connections = autopilotDeliveryWriters{"provider": w}
	})
	r.selectLiveMachines(t, 0)
	p := autopilotControllerProvider(t, r, "provider", now)
	stalePlan := autopilotControllerPlan(t, r, c, now)
	c.RefreshControlLeases(now)
	if !r.BindVerifiedMachineIdentity(p, p.AccountID, r.machineID(t, 1)) {
		t.Fatal("identity rebind rejected")
	}
	// The old grant was enqueued before demotion but reaches the socket later.
	// Delivery cannot reapply coordinator authority or clear accepted owners.
	oldGrant := readAutopilotControl(t, w)
	if oldGrant.ObserveOnly {
		t.Fatal("fixture did not retain the old live grant")
	}
	state := autopilotControllerState()
	state.SessionID = p.ID
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: state})
	p.Mu().Lock()
	active := r.states[p.ID].ControlActive(p.ModelAutopilot, p.ID, time.Now())
	p.Mu().Unlock()
	if active {
		t.Fatal("delayed live acknowledgement restored a revoked binding's lease")
	}
	if _, ok := c.Reserve(stalePlan, now); ok {
		t.Fatal("old queued live grant let a nonmember reserve")
	}
	c.RefreshControlLeases(now)
	if control := readAutopilotControl(t, w); !control.ObserveOnly {
		t.Fatal("rebound nonmember did not receive shadow renewal")
	}
	// Even rebinding to the selected UUID cannot reuse that old live report.
	if !r.BindVerifiedMachineIdentity(p, p.AccountID, r.machineID(t, 0)) {
		t.Fatal("selected rebind rejected")
	}
	c.RefreshControlLeases(now)
	if readAutopilotControl(t, w).ObserveOnly {
		t.Fatal("selected machine lost live eligibility")
	}
	p.Mu().Lock()
	active = r.states[p.ID].ControlActive(p.ModelAutopilot, p.ID, time.Now())
	p.Mu().Unlock()
	if active || autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
		t.Fatal("selected rebind reused a stored acknowledgement from the old grant")
	}
	// A new accepted report can acknowledge the current grant. The wire protocol
	// has no grant-generation field; this is receipt ordering, not a wire epoch.
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(12), ModelAutopilot: state})
	p.Mu().Lock()
	active = r.states[p.ID].ControlActive(p.ModelAutopilot, p.ID, time.Now())
	p.Mu().Unlock()
	if !active {
		t.Fatal("current selected binding could not acknowledge the new grant")
	}
}

func TestAutopilotConcurrentRenewalCannotOverwriteIdentityDemotion(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	w := newWriterFixture(0, 256, nil, nil, nil, nil)
	t.Cleanup(func() { w.Close(); w.Run() })
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
		d.Connections = autopilotDeliveryWriters{"provider": w}
	})
	r.selectLiveMachines(t, 0)
	p := autopilotControllerProvider(t, r, "provider", now)
	for i := range 100 {
		if !r.BindVerifiedMachineIdentity(p, p.AccountID, r.machineID(t, 0)) {
			t.Fatal("selected rebind rejected")
		}
		var wg sync.WaitGroup
		wg.Add(1)
		go func() { defer wg.Done(); c.RefreshControlLeases(now) }()
		if !r.BindVerifiedMachineIdentity(p, p.AccountID, r.machineID(t, 1)) {
			t.Fatal("demotion rejected")
		}
		wg.Wait()
		state := autopilotControllerState()
		state.SessionID = p.ID
		r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(uint64(11 + i)), ModelAutopilot: state})
		p.Mu().Lock()
		active := r.states[p.ID].ControlActive(p.ModelAutopilot, p.ID, time.Now())
		p.Mu().Unlock()
		if active {
			t.Fatal("a staged live renewal replaced a newer identity demotion")
		}
	}
}

func TestAutopilotMachineDemotionRetainsAcceptedOperationRecovery(t *testing.T) {
	for _, demotion := range []string{"identity", "desired shadow"} {
		for _, status := range []string{"reserved", protocol.LoadModelStatusStarted} {
			for _, terminal := range []string{"heartbeat", "disconnect"} {
				t.Run(demotion+"/"+status+"/"+terminal, func(t *testing.T) {
					cfg := autopilot.DefaultConfig()
					cfg.ObserveOnly = false
					var commands []protocol.ModelAutopilotMessage
					r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
						d.AutopilotSender = func(_ string, cmd protocol.ModelAutopilotMessage) error { commands = append(commands, cmd); return nil }
					})
					r.selectLiveMachines(t, 0)
					p := autopilotControllerProvider(t, r, "provider", now)
					if c.Tick(now).Issued != 1 {
						t.Fatal("fixture did not issue a live operation")
					}
					command := commands[0]
					if status != "reserved" && !r.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: command.CommandID, Status: status}) {
						t.Fatal("provider acceptance rejected")
					}
					if demotion == "desired shadow" {
						if _, err := r.SetMachineAutopilotDesiredMode(context.Background(), r.machineID(t, 0), store.MachineAutopilotShadow); err != nil {
							t.Fatal(err)
						}
					} else if !r.BindVerifiedMachineIdentity(p, p.AccountID, r.machineID(t, 1)) {
						t.Fatal("identity demotion rejected")
					}
					r.SetAutopilotPaused(true)
					summary := c.Tick(now.Add(31 * time.Second))
					if summary.LiveCohort != 0 || summary.Shadow != 1 || summary.Pending != 1 || summary.Issued != 0 || len(commands) != 2 || !reflect.DeepEqual(commands[0], commands[1]) {
						t.Fatalf("demotion/pause lost exact accepted-command recovery: %+v commands=%+v", summary, commands)
					}
					c.Watchdogs(now.Add(cfg.CommandWatchdog + time.Second))
					p.Mu().Lock()
					pending, owned := r.states[p.ID].PrepareDelivery()
					fenced := r.states[p.ID].LegacyChangesBlocked(p.ModelAutopilot, p.ID, time.Now) && r.states[p.ID].RoutingBlocked(p.ModelAutopilot, p.ID, autopilotTestTarget, p.BackendCapacity, time.Now)
					p.Mu().Unlock()
					if !owned || !pending.Uncertain || !fenced || pending.Command.CommandID != command.CommandID {
						t.Fatal("demotion lost pending owner, watchdog or routing fence")
					}
					if terminal == "disconnect" {
						r.Disconnect(p.ID)
						p.Mu().Lock()
						pending, owned = r.states[p.ID].PrepareDelivery()
						p.Mu().Unlock()
						if !owned || !pending.Uncertain || pending.Command.CommandID != command.CommandID {
							t.Fatal("disconnect erased unresolved demoted operation")
						}
						return
					}
					state := autopilotControllerState(autopilotTestTarget)
					state.Active, state.ObserveOnly, state.SessionID = false, true, p.ID
					state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusSucceeded
					r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11, autopilotTestTarget), ModelAutopilot: state, WarmModels: []string{autopilotTestTarget}})
					p.Mu().Lock()
					_, owned = r.states[p.ID].PrepareDelivery()
					p.Mu().Unlock()
					if owned {
						t.Fatal("matching authoritative terminal report could not resolve demoted operation")
					}
				})
			}
		}
	}
}
