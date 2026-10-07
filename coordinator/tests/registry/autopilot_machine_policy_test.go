package registry_test

import (
	"context"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotMachineDesiredShadowRevokesBeforeReturningDespiteWriter(t *testing.T) {
	for _, writerMode := range []string{"blocked", "full", "nil"} {
		t.Run(writerMode, func(t *testing.T) {
			writers := autopilotDeliveryWriters{}
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = false
			r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) { d.Connections = writers })
			r.selectLiveMachines(t, 0)
			machineID := r.machineID(t, 0)
			var w *writerFixture
			var edited chan struct{}
			t.Cleanup(func() {
				if edited != nil {
					select {
					case <-edited:
					case <-time.After(2 * time.Second):
						t.Error("admin edit did not finish after releasing the writer")
					}
				}
			})
			writeEntered, releaseWrite, writerDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
			var enteredOnce sync.Once
			runStarted := false
			if writerMode != "nil" {
				w = newWriterFixture(0, 1, nil, nil, func([]byte) error {
					enteredOnce.Do(func() { close(writeEntered) })
					<-releaseWrite
					return nil
				}, nil)
				writers["provider"] = w
				t.Cleanup(func() {
					close(releaseWrite)
					w.Close()
					if runStarted {
						<-writerDone
					} else {
						w.Run()
					}
				})
			}
			p := autopilotMachineProvider(t, r, "provider", machineID, now)
			stale := autopilotControllerPlan(t, r, c, now)
			before := autopilot.CloneState(p.ModelAutopilot)
			if writerMode == "blocked" {
				runStarted = true
				go func() { w.Run(); close(writerDone) }()
				c.RefreshControlLeases(now)
				select {
				case <-writeEntered:
				case <-time.After(time.Second):
					t.Fatal("fixture did not block a live control write")
				}
			} else if writerMode == "full" {
				w.offer(providerwrite.NewFrame(nil, nil), true)
			}
			edited = make(chan struct{})
			var status production.MachineAutopilotStatus
			var err error
			go func() {
				status, err = r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotShadow)
				close(edited)
			}()
			select {
			case <-edited:
			case <-time.After(time.Second):
				t.Fatal("desired shadow waited for a control writer")
			}
			if err != nil || status.DesiredMode != store.MachineAutopilotShadow || status.Revision != 2 || len(status.Sessions) != 1 || status.Sessions[0].ControlActive || status.Sessions[0].EffectiveMode != "shadow" {
				t.Fatalf("demotion did not publish durable intent and revoked authority before return: status=%+v error=%v", status, err)
			}
			if autopilotMachineControlActive(r, p) {
				t.Fatal("undelivered shadow control retained the old live acknowledgement")
			}
			if _, ok := c.Reserve(stale, now); ok {
				t.Fatal("detached live plan reserved after the desired mode was shadow")
			}
			p.Mu().Lock()
			_, pending := r.states[p.ID].PrepareDelivery()
			blocked := r.states[p.ID].LegacyChangesBlocked(p.ModelAutopilot, p.ID, time.Now) || r.states[p.ID].RoutingBlocked(p.ModelAutopilot, p.ID, autopilotTestTarget, p.BackendCapacity, time.Now)
			unchanged := reflect.DeepEqual(before, p.ModelAutopilot) && len(p.BackendCapacity.Slots) == 0 && len(p.WarmModels) == 0
			p.Mu().Unlock()
			if pending || blocked || !unchanged {
				t.Fatal("demotion acquired work or rewrote provider-owned capacity and consent")
			}
		})
	}
}

func TestAutopilotMachinePromotionRequiresFreshAckAndSameModePreservesIt(t *testing.T) {
	for _, cached := range []bool{false, true} {
		t.Run(map[bool]string{false: "memory", true: "cached memory"}[cached], func(t *testing.T) {
			w := newWriterFixture(0, 8, nil, nil, nil, nil)
			t.Cleanup(func() { w.Close(); w.Run() })
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = false
			r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) { d.Connections = autopilotDeliveryWriters{"provider": w} })
			if cached {
				r.SetStore(store.NewCached(r.store, store.CacheConfig{}))
			}
			machineID := r.machineID(t, 0)
			p := autopilotMachineProvider(t, r, "provider", machineID, now)
			initial := autopilotMachineStatus(t, r, machineID)
			if initial.DesiredMode != store.MachineAutopilotShadow || initial.Revision != 0 || initial.Sessions[0].ControlActive {
				t.Fatalf("unconfigured machine gained control: %+v", initial)
			}
			for _, revision := range []int64{1, 3} {
				status, err := r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotLive)
				control := readAutopilotControl(t, w)
				if err != nil || status.Revision != revision || status.Sessions[0].EffectiveMode != "awaiting_ack" || status.Sessions[0].ControlActive || control.ObserveOnly || !control.Enabled {
					t.Fatalf("promotion reused an old acknowledgement: status=%+v control=%+v error=%v", status, control, err)
				}
				if autopilotMachineControlActive(r, p) || autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
					t.Fatal("desired live alone made a provider reservable")
				}
				seq := uint64(11 + revision/2)
				now = acknowledgeAutopilotMachine(r, p, control, seq-1)
				if autopilotMachineControlActive(r, p) {
					t.Fatal("duplicate capacity heartbeat acknowledged a fresh grant")
				}
				now = acknowledgeAutopilotMachine(r, p, control, seq)
				if !autopilotMachineControlActive(r, p) {
					t.Fatal("fresh accepted capacity heartbeat could not activate live control")
				}
				action := autopilotControllerPlan(t, r, c, now)
				status, err = r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotLive)
				control = readAutopilotControl(t, w)
				if err != nil || status.Revision != revision || !status.Sessions[0].ControlActive || status.Sessions[0].EffectiveMode != "live" || control.ObserveOnly || !autopilotMachineControlActive(r, p) {
					t.Fatalf("same-mode edit reset revision or live acknowledgement: status=%+v error=%v", status, err)
				}
				if revision == 3 {
					if _, ok := c.Reserve(action, now); !ok {
						t.Fatal("idempotent live write invalidated an acknowledged detached plan")
					}
					break
				}
				status, err = r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotShadow)
				if control = readAutopilotControl(t, w); err != nil || status.Revision != 2 || !control.ObserveOnly || autopilotMachineControlActive(r, p) {
					t.Fatalf("shadow edit retained live authority: status=%+v error=%v", status, err)
				}
				// No provider report acknowledges shadow before re-promotion. The
				// previously stored active report still must not authorize the new grant.
			}
		})
	}
}

func TestAutopilotMachineDemotionRevokesEveryBoundSessionOnly(t *testing.T) {
	writers := autopilotDeliveryWriters{}
	for _, id := range []string{"a-session", "b-session", "other-machine"} {
		w := newWriterFixture(0, 4, nil, nil, nil, nil)
		writers[id] = w
		t.Cleanup(func() { w.Close(); w.Run() })
	}
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) { d.Connections = writers })
	r.selectLiveMachines(t, 0, 1)
	machineID := r.machineID(t, 0)
	a := autopilotMachineProvider(t, r, "a-session", machineID, now)
	b := autopilotMachineProvider(t, r, "b-session", machineID, now)
	other := autopilotMachineProvider(t, r, "other-machine", r.machineID(t, 1), now)
	status, err := r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotShadow)
	if err != nil || len(status.Sessions) != 2 || status.Sessions[0].ProviderID != a.ID || status.Sessions[1].ProviderID != b.ID {
		t.Fatalf("canonical machine did not project both bound sessions: %+v error=%v", status, err)
	}
	for _, p := range []*production.Provider{a, b, other} {
		control := readAutopilotControl(t, writers[p.ID])
		if control.ObserveOnly != (p != other) || autopilotMachineControlActive(r, p) != (p == other) {
			t.Fatalf("per-machine demotion missed a sibling or revoked another machine: provider=%s control=%+v", p.ID, control)
		}
	}
	for _, session := range status.Sessions {
		if session.ControlActive || session.EffectiveMode != "shadow" {
			t.Fatalf("demotion returned an active sibling: %+v", session)
		}
	}
	otherStatus := autopilotMachineStatus(t, r, r.machineID(t, 1))
	if otherStatus.Revision != 1 || otherStatus.DesiredMode != store.MachineAutopilotLive || !otherStatus.Sessions[0].ControlActive {
		t.Fatalf("another machine's idempotent renewal lost authority: %+v", otherStatus)
	}
	if action := autopilotControllerPlan(t, r, c, now); action.Node.ID != other.ID {
		t.Fatalf("demoted machine remained a live recipient: %+v", action.Node)
	}
}

func TestAutopilotMachineDesiredModeReloadsWithoutIdentityOrAckOnRegistryRestart(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	old, _, now := newAutopilotControllerTestConfig(t, cfg)
	old.selectLiveMachines(t, 0)
	machineID := old.machineID(t, 0)
	previous := autopilotMachineProvider(t, old, "old-session", machineID, now)
	old.Disconnect(previous.ID)
	w := newWriterFixture(0, 4, nil, nil, nil, nil)
	t.Cleanup(func() { w.Close(); w.Run() })
	r, controller := newAutopilotFixture(cfg, func(d *production.Dependencies) { d.Connections = autopilotDeliveryWriters{"new-session": w} })
	r.SetStore(old.store)
	r.SetModelCatalog([]production.CatalogEntry{{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16}, {ID: autopilotTestDonor, SizeGB: 8, MinRAMGB: 16}})
	warm := testWarmPoolConfig()
	warm.MinWarmByModel = map[string]int{autopilotTestTarget: 1}
	r.ConfigureWarmPool(warm)
	if err := r.ConfigureAutopilot(cfg); err != nil {
		t.Fatal(err)
	}
	c := *controller
	p := autopilotMachineProvider(t, r, "new-session", "", now)
	c.RefreshControlLeases(now)
	if control := readAutopilotControl(t, w); !control.ObserveOnly || autopilotMachineControlActive(r, p) {
		t.Fatal("persisted machine settings restored a prior connection's identity or authority")
	}
	if status := autopilotMachineStatus(t, r, machineID); status.Revision != 1 || status.DesiredMode != store.MachineAutopilotLive || len(status.Sessions) != 0 {
		t.Fatalf("restart lost durable intent or restored historical session bindings: %+v", status)
	}
	if !r.BindVerifiedMachineIdentity(p, p.AccountID, machineID) {
		t.Fatal("new verified machine binding rejected")
	}
	now = acknowledgeAutopilotMachine(r, p, protocol.ModelAutopilotControl{Enabled: true, SessionID: p.ID, Revision: "test"}, 11)
	c.RefreshControlLeases(now)
	control := readAutopilotControl(t, w)
	if control.ObserveOnly || autopilotMachineControlActive(r, p) || autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
		t.Fatal("a stored active report became the fresh acknowledgement after restart")
	}
	now = acknowledgeAutopilotMachine(r, p, control, 12)
	if !autopilotMachineControlActive(r, p) {
		t.Fatal("reloaded machine could not acknowledge its new-session grant")
	}
	if _, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now); !ok {
		t.Fatal("reloaded desired mode did not become usable after binding and fresh acknowledgement")
	}
}
