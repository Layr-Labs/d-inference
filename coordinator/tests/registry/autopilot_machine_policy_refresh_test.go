package registry_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotMachineExternalChangesTakeEffectOnNextTick(t *testing.T) {
	for _, change := range []string{"demote", "promote", "off-on between polls"} {
		t.Run(change, func(t *testing.T) {
			w := newWriterFixture(0, 4, nil, nil, nil, nil)
			t.Cleanup(func() { w.Close(); w.Run() })
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = false
			r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) { d.Connections = autopilotDeliveryWriters{"provider": w} })
			initiallyLive := change != "promote"
			if initiallyLive {
				r.selectLiveMachines(t, 0)
			}
			machineID := r.machineID(t, 0)
			p := autopilotMachineProvider(t, r, "provider", machineID, now)
			var stale autopilotcontrol.Action[*production.Provider]
			if initiallyLive {
				stale = autopilotControllerPlan(t, r, c, now)
			}
			settings, ok := store.As[store.MachineAutopilotStore](r.store)
			if !ok {
				t.Fatal("real fixture backend has no machine settings")
			}
			mode := store.MachineAutopilotShadow
			if change == "promote" {
				mode = store.MachineAutopilotLive
			}
			setting, err := settings.SetMachineAutopilotDesiredMode(context.Background(), machineID, mode)
			if err != nil {
				t.Fatal(err)
			}
			if change == "off-on between polls" {
				setting, err = settings.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotLive)
				if err != nil || setting.Revision != 3 {
					t.Fatalf("external round trip did not advance the persisted revision: %+v error=%v", setting, err)
				}
			}
			if autopilotMachineControlActive(r, p) != initiallyLive || w.lanes.Depth(true) != 0 {
				t.Fatal("out-of-process edit applied before the registry refreshed it")
			}
			summary := c.Tick(now)
			control := readAutopilotControl(t, w)
			live := change != "demote"
			if summary.LiveActive != 0 || summary.Issued != 0 || summary.LiveProposed != 0 || control.ObserveOnly == live || autopilotMachineControlActive(r, p) {
				t.Fatalf("tick reused pre-edit authority: summary=%+v control=%+v", summary, control)
			}
			if live && (summary.LiveCohort != 1 || summary.Shadow != 0) || !live && (summary.LiveCohort != 0 || summary.Shadow != 1 || summary.ShadowProposed != 1) {
				t.Fatalf("tick did not publish the new desired mode: %+v", summary)
			}
			if initiallyLive {
				if _, ok := c.Reserve(stale, now); ok {
					t.Fatal("detached plan survived a mode change or an unseen off/on revision gap")
				}
			}
			if live {
				if autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
					t.Fatal("refreshed live intent acquired authority without a fresh acknowledgement")
				}
				now = acknowledgeAutopilotMachine(r, p, control, 11)
				if _, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now); !ok {
					t.Fatal("fresh acknowledgement did not activate externally promoted machine")
				}
			}
		})
	}
}

func TestAutopilotMachinePolicyFailureRevokesAndRecoveryRequiresFreshAck(t *testing.T) {
	for _, failure := range []string{"read", "committed write", "missing capability"} {
		t.Run(failure, func(t *testing.T) {
			w := newWriterFixture(0, 4, nil, nil, nil, nil)
			t.Cleanup(func() { w.Close(); w.Run() })
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = false
			r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) { d.Connections = autopilotDeliveryWriters{"provider": w} })
			r.selectLiveMachines(t, 0)
			machineID := r.machineID(t, 0)
			probe := newAutopilotMachineStoreProbe(t, r.store)
			capabilities := &autopilotCapabilityStore{Store: probe}
			r.SetStore(capabilities)
			p := autopilotMachineProvider(t, r, "provider", machineID, now)
			stale := autopilotControllerPlan(t, r, c, now)
			t.Setenv(env.EnvPrefix+"_AUTOPILOT_LIVE_MACHINE_IDS", machineID)
			switch failure {
			case "read":
				probe.failRead.Store(true)
				if summary := c.Tick(now); summary.LiveCohort != 0 || summary.LiveActive != 0 || summary.Issued != 0 || summary.ShadowProposed != 1 {
					t.Fatalf("failed DB refresh kept live policy or lost genuine shadow planning: %+v", summary)
				}
			case "committed write":
				probe.failWrite.Store(true)
				if _, err := r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotLive); !errors.Is(err, errAutopilotMachineStore) {
					t.Fatalf("ambiguous store write was not surfaced: %v", err)
				}
			case "missing capability":
				capabilities.unavailable.Store(true)
				c.RefreshControlLeases(now)
			}
			if control := readAutopilotControl(t, w); !control.ObserveOnly || autopilotMachineControlActive(r, p) {
				t.Fatal("unavailable durable policy retained authority or fell back to the removed environment selector")
			}
			if _, ok := c.Reserve(stale, now); ok {
				t.Fatal("a detached live plan bypassed policy-store failure")
			}
			probe.failRead.Store(false)
			probe.failWrite.Store(false)
			capabilities.unavailable.Store(false)
			c.RefreshControlLeases(now)
			control := readAutopilotControl(t, w)
			status := autopilotMachineStatus(t, r, machineID)
			if control.ObserveOnly || status.DesiredMode != store.MachineAutopilotLive || status.Revision != 1 || status.Sessions[0].EffectiveMode != "awaiting_ack" || autopilotMachineControlActive(r, p) {
				t.Fatalf("store recovery reused stale acknowledgement or lost durable mode: %+v control=%+v", status, control)
			}
			if autopilotcontrol.Plan(c.Fleet(now), cfg, now) != nil {
				t.Fatal("recovered DB policy alone restored a reservation")
			}
			now = acknowledgeAutopilotMachine(r, p, control, 11)
			if _, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now); !ok {
				t.Fatal("store recovery never restored control after a fresh acknowledgement")
			}
		})
	}
}

func TestAutopilotMachineRefreshCannotOverwriteConcurrentAdminDemotion(t *testing.T) {
	w := newWriterFixture(0, 8, nil, nil, nil, nil)
	t.Cleanup(func() { w.Close(); w.Run() })
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly = false
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) { d.Connections = autopilotDeliveryWriters{"provider": w} })
	r.selectLiveMachines(t, 0)
	machineID := r.machineID(t, 0)
	probe := newAutopilotMachineStoreProbe(t, r.store)
	r.SetStore(probe)
	p := autopilotMachineProvider(t, r, "provider", machineID, now)
	stale := autopilotControllerPlan(t, r, c, now)
	probe.blockRead.Store(true)
	refreshed := make(chan struct{})
	go func() { c.RefreshControlLeases(now); close(refreshed) }()
	// Always release the store barrier before waiting on either operation,
	// including failed assertions. The real store read has already captured live.
	var edited chan struct{}
	var available chan struct{}
	var editError error
	t.Cleanup(func() {
		probe.resumeRead()
		<-refreshed
		if edited != nil {
			<-edited
		}
		if available != nil {
			<-available
		}
	})
	select {
	case <-probe.readEntered:
	case <-time.After(time.Second):
		t.Fatal("refresh did not reach the completed DB-read barrier")
	}
	available = make(chan struct{})
	go func() {
		_ = c.Fleet(now)
		p.Mu().Lock()
		p.Mu().Unlock()
		close(available)
	}()
	select {
	case <-available:
	case <-time.After(time.Second):
		t.Fatal("policy-store read held registry or provider locks")
	}
	edited = make(chan struct{})
	editStarted := make(chan struct{})
	go func() {
		close(editStarted)
		_, editError = r.SetMachineAutopilotDesiredMode(context.Background(), machineID, store.MachineAutopilotShadow)
		close(edited)
	}()
	<-editStarted
	select {
	case <-probe.writeEntered:
		// Without serialization, complete the edit before releasing the older
		// read, so that a stale publication cannot accidentally win the test.
		<-edited
		if editError != nil {
			t.Errorf("concurrent edit failed: %v", editError)
		}
		t.Error("admin write raced past an unpublished policy refresh")
	case <-time.After(25 * time.Millisecond):
	}
	probe.resumeRead()
	select {
	case <-refreshed:
	case <-time.After(time.Second):
		t.Fatal("released refresh did not finish")
	}
	select {
	case <-edited:
		if editError != nil {
			t.Fatal(editError)
		}
	case <-time.After(time.Second):
		t.Fatal("admin edit did not finish after refresh publication")
	}
	status := autopilotMachineStatus(t, r, machineID)
	if status.DesiredMode != store.MachineAutopilotShadow || status.Revision != 2 || status.Sessions[0].EffectiveMode != "shadow" || autopilotMachineControlActive(r, p) {
		t.Fatalf("older DB snapshot overwrote the completed admin demotion: %+v", status)
	}
	if _, ok := c.Reserve(stale, now); ok {
		t.Fatal("concurrent refresh revived a detached plan after completed admin demotion")
	}
	for w.lanes.Depth(true) > 0 {
		readAutopilotControl(t, w)
	}
}
