package registry_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotledger"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

const (
	autopilotTestTarget = "controller-target"
	autopilotTestDonor  = "controller-donor"
)

type autopilotFixture struct {
	*production.Registry
	cfg          autopilot.Config
	demand       *autopilot.DemandTracker
	states       map[string]*autopilotstate.State
	leases       map[string]*autopilotstate.Lease
	samples      map[string]*capacityvalue.SampleHistory
	store        store.Store
	events       *autopilotledger.Events
	loads        *production.ModelLoadPlanner
	pendingLoads *pendingload.Ledger
	machineIDs   map[string]string
}

func newAutopilotControllerTest(t *testing.T, observe bool, configure ...func(*production.Dependencies)) (*autopilotFixture, *autopilotcontrol.Controller[*production.Provider], time.Time) {
	t.Helper()
	cfg := autopilot.DefaultConfig()
	cfg.Enabled, cfg.ObserveOnly = true, observe
	r, c, now := newAutopilotControllerTestConfig(t, cfg, configure...)
	for i := range 16 {
		r.selectLiveMachines(t, i)
	}
	return r, c, now
}

func newAutopilotControllerTestConfig(t *testing.T, cfg autopilot.Config, configure ...func(*production.Dependencies)) (*autopilotFixture, *autopilotcontrol.Controller[*production.Provider], time.Time) {
	t.Helper()
	r, c := newAutopilotFixture(cfg, configure...)
	r.SetStore(memory.NewMemory(store.Config{}))
	r.SetModelCatalog([]production.CatalogEntry{{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16}, {ID: autopilotTestDonor, SizeGB: 8, MinRAMGB: 16}})
	warm := testWarmPoolConfig()
	warm.MinWarmByModel = map[string]int{autopilotTestTarget: 1}
	r.ConfigureWarmPool(warm)
	if err := r.ConfigureAutopilot(cfg); err != nil {
		t.Fatal(err)
	}
	return r, *c, time.Now()
}

// Factories retain the exact owners used by the registry. No fixture state is
// substituted for placement, sequence gating, or command reconciliation.
func newAutopilotFixture(cfg autopilot.Config, configure ...func(*production.Dependencies)) (*autopilotFixture, **autopilotcontrol.Controller[*production.Provider]) {
	r := &autopilotFixture{cfg: cfg, demand: &autopilot.DemandTracker{}, states: map[string]*autopilotstate.State{}, leases: map[string]*autopilotstate.Lease{}, samples: map[string]*capacityvalue.SampleHistory{}, events: &autopilotledger.Events{}, pendingLoads: &pendingload.Ledger{}, machineIDs: map[string]string{}}
	var control *autopilotcontrol.Controller[*production.Provider]
	deps := production.Dependencies{
		AutopilotControl: func(actual *autopilotcontrol.Controller[*production.Provider]) autopilotcontrol.Operations[*production.Provider] {
			control = actual
			return actual
		},
		AutopilotDemand: r.demand,
		AutopilotEvents: r.events,
		PendingLoads:    r.pendingLoads,
		AutopilotState: func(id string) *autopilotstate.State {
			lease := &autopilotstate.Lease{}
			r.leases[id] = lease
			state := autopilotstate.New(lease)
			r.states[id] = state
			return state
		},
		CapacitySamples: func(id string) *capacityvalue.SampleHistory {
			history := &capacityvalue.SampleHistory{}
			r.samples[id] = history
			return history
		},
		ModelLoadPlanning: func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
			r.loads = actual
			return actual
		},
	}
	for _, configure := range configure {
		configure(&deps)
	}
	r.pendingLoads = deps.PendingLoads
	r.Registry = production.NewWithDependencies(testLogger(), deps)
	return r, &control
}

func (r *autopilotFixture) SetStore(s store.Store) {
	r.store = s
	r.Registry.SetStore(s)
}

func (r *autopilotFixture) machineID(t testing.TB, index int) string {
	t.Helper()
	inventory, ok := store.As[store.MachineInventoryStore](r.store)
	if !ok {
		t.Fatal("fixture store has no machine inventory")
	}
	identity, err := inventory.ObserveMachine(context.Background(), store.MachineObservation{
		SessionID: fmt.Sprintf("fixture-machine-%d", index), AccountID: "autopilot-fixture-owner",
		VerifiedAppAttestKey: fmt.Sprintf("fixture-app-attest-key-%d", index), At: time.Now(), Source: "test",
	})
	if err != nil || identity.ID == "" {
		t.Fatalf("observe fixture machine: identity=%+v error=%v", identity, err)
	}
	return identity.ID
}

func (r *autopilotFixture) selectLiveMachines(t testing.TB, indices ...int) {
	t.Helper()
	for _, index := range indices {
		if _, err := r.SetMachineAutopilotDesiredMode(context.Background(), r.machineID(t, index), store.MachineAutopilotLive); err != nil {
			t.Fatalf("select fixture machine %d: %v", index, err)
		}
	}
}

func autopilotControllerProvider(t *testing.T, r *autopilotFixture, id string, now time.Time, residents ...string) *production.Provider {
	t.Helper()
	machineID, ok := r.machineIDs[id]
	if !ok {
		machineID = r.machineID(t, len(r.machineIDs))
		r.machineIDs[id] = machineID
	}
	return autopilotMachineProvider(t, r, id, machineID, now, residents...)
}

func autopilotMachineProvider(t *testing.T, r *autopilotFixture, id, machineID string, now time.Time, residents ...string) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r.Registry, id, autopilotTestTarget, 100, autopilotTestDonor)
	p.Mu().Lock()
	p.AccountID = "autopilot-fixture-owner"
	p.Mu().Unlock()
	if machineID != "" && !r.BindVerifiedMachineIdentity(p, "autopilot-fixture-owner", machineID) {
		t.Fatal("fixture verified machine binding rejected")
	}
	settings, ok := store.As[store.MachineAutopilotStore](r.store)
	if !ok {
		t.Fatal("fixture store has no machine Autopilot settings")
	}
	selected, err := settings.LiveMachineAutopilotSettings(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	live := false
	for _, setting := range selected {
		live = live || setting.MachineID == machineID
	}
	observe := r.cfg.ObserveOnly || !live
	state := autopilotControllerState(residents...)
	state.Active, state.ObserveOnly, state.SessionID = !observe, observe, id
	p.Mu().Lock()
	p.Hardware.MemoryGB = 64
	p.PrefillTPS = 2000
	p.Models = []protocol.ModelInfo{{ID: autopilotTestTarget, SizeBytes: 8_000_000_000, ModelType: "chat"}, {ID: autopilotTestDonor, SizeBytes: 8_000_000_000, ModelType: "chat"}}
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: .1, CPUUsage: .1, ThermalState: "nominal"}
	p.ModelAutopilot = state
	r.states[id].AcceptControl(state, protocol.ModelAutopilotControl{SessionID: id, Revision: "test", Enabled: true, ObserveOnly: observe, ExpiresAtMS: now.Add(time.Hour).UnixMilli()})
	metrics := p.SystemMetrics
	p.Mu().Unlock()
	// The accepted capacity heartbeat acknowledges the fixture's current grant.
	r.Heartbeat(id, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(10, residents...), ModelAutopilot: state, WarmModels: residents, SystemMetrics: metrics})
	p.Mu().Lock()
	r.samples[id].MarkAccepted(now)
	p.Mu().Unlock()
	return p
}

func autopilotControllerState(residents ...string) *protocol.ModelAutopilotState {
	free := 48.0
	s := &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Active: true, SessionID: "provider", Revision: "test", SelectedModels: []string{autopilotTestTarget, autopilotTestDonor}, MinIdleSeconds: 60, Enabled: true, CachedOnly: true, MaxModelSlots: 3, MinDwellSeconds: 60, FreeForLoadNoEvictGB: &free, ResidentModels: []protocol.ModelAutopilotResident{}, PinnedModels: []string{}}
	for _, m := range residents {
		resident := 8.0
		s.ResidentModels = append(s.ResidentModels, protocol.ModelAutopilotResident{ModelID: m, ResidentSeconds: 7200, IdleSeconds: 7200, WeightsGB: 9, ResidentGB: &resident})
	}
	return s
}

func autopilotControllerCapacity(seq uint64, residents ...string) *protocol.BackendCapacity {
	bc := &protocol.BackendCapacity{TotalMemoryGB: 64, CapacitySeq: seq, Slots: []protocol.BackendSlotCapacity{}}
	for _, m := range residents {
		bc.Slots = append(bc.Slots, protocol.BackendSlotCapacity{Model: m, State: "idle", ActiveTokenBudgetMax: 100000, KVBytesPerToken: 65536, MaxConcurrency: 8})
	}
	return bc
}

func autopilotControllerPlan(t *testing.T, r *autopilotFixture, c *autopilotcontrol.Controller[*production.Provider], now time.Time) autopilotcontrol.Action[*production.Provider] {
	t.Helper()
	f := c.Fleet(now)
	a := autopilotcontrol.Plan(f, r.cfg, now)
	if a == nil {
		t.Fatalf("fixture should plan a target load: fleet=%+v summary=%+v", f, autopilot.Summarize(f.Fleet, r.cfg, now))
	}
	return *a
}
