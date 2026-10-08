package registry_test

import (
	"encoding/json"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotMachineModelsProjectionOwnsItsValues(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	r, _, now := newAutopilotControllerTestConfig(t, cfg)
	machineID := r.machineID(t, 0)
	p := autopilotMachineProvider(t, r, "provider", machineID, now)
	state := autopilotControllerState(autopilotTestTarget, autopilotTestDonor)
	state.PinnedModels = []string{autopilotTestTarget, autopilotTestDonor}
	minutes := 0
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", IdleUnloadMins: &minutes, ModelAutopilot: state,
		BackendCapacity: autopilotControllerCapacity(11, autopilotTestTarget, autopilotTestDonor),
	})
	session := autopilotMachineStatus(t, r, machineID).Sessions[0]
	want := []string{autopilotTestDonor, autopilotTestTarget}
	if !slices.Equal(session.PinnedModels, want) || !slices.Equal(session.ResidentModels, want) || session.IdleUnloadMins == nil || session.AlwaysReadyConfigured == nil || !*session.AlwaysReadyConfigured || session.LastHeartbeat == nil || session.CapacityAcceptedAt == nil {
		t.Fatalf("missing reported policy: %+v", session)
	}
	heartbeatAt, capacityAt := *session.LastHeartbeat, *session.CapacityAcceptedAt
	session.PinnedModels[0], session.ResidentModels[0] = "changed-pin", "changed-resident"
	*session.IdleUnloadMins, *session.AlwaysReadyConfigured = 999, false
	*session.LastHeartbeat, *session.CapacityAcceptedAt = time.Time{}, time.Time{}

	again := autopilotMachineStatus(t, r, machineID).Sessions[0]
	if !slices.Equal(again.PinnedModels, want) || !slices.Equal(again.ResidentModels, want) || *again.IdleUnloadMins != 0 || !*again.AlwaysReadyConfigured || !again.LastHeartbeat.Equal(heartbeatAt) || !again.CapacityAcceptedAt.Equal(capacityAt) {
		t.Fatalf("caller mutated registry through a diagnostic projection: %+v", again)
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.ModelAutopilot.PinnedModels[0] != autopilotTestTarget || p.ModelAutopilot.ResidentModels[0].ModelID != autopilotTestTarget {
		t.Fatal("sorting the diagnostic mutated provider-owned list order")
	}
}

func TestAutopilotMachineModelsKeepReportsSeparateFromFreshness(t *testing.T) {
	for _, tc := range []struct {
		name      string
		live      bool
		age       time.Duration
		wantFresh bool
	}{
		{"ordinary donor window", false, 45 * time.Second, true},
		{"stale shadow", false, 2 * time.Minute, false},
		{"live control window", true, 45 * time.Second, false},
		{"fresh live", true, 5 * time.Second, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reportedAt := time.Now().Add(-tc.age)
			cfg := autopilot.DefaultConfig()
			cfg.Enabled, cfg.ObserveOnly = true, false
			r, _, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
				d.HeartbeatNow = func() time.Time { return reportedAt }
			})
			if tc.live {
				r.selectLiveMachines(t, 0)
			}
			machineID := r.machineID(t, 0)
			p := autopilotMachineProvider(t, r, "provider", machineID, now, autopilotTestDonor)
			p.Mu().Lock()
			state := autopilot.CloneState(p.ModelAutopilot)
			p.Mu().Unlock()
			state.PinnedModels = []string{autopilotTestDonor}
			minutes := 0
			r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
				Status: "idle", IdleUnloadMins: &minutes, ModelAutopilot: state,
				BackendCapacity: autopilotControllerCapacity(11, autopilotTestDonor),
			})
			// A rejected sequence proves liveness, not fresh policy or capacity.
			if r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
				Status: "idle", BackendCapacity: autopilotControllerCapacity(10),
			}) {
				t.Fatal("old capacity sequence accepted")
			}
			session := autopilotMachineStatus(t, r, machineID).Sessions[0]
			if session.CapacityFresh != tc.wantFresh || session.ControlActive != tc.live || session.CapacityAcceptedAt == nil || !session.CapacityAcceptedAt.Equal(reportedAt) || session.LastHeartbeat == nil || !session.LastHeartbeat.After(reportedAt) {
				t.Fatalf("liveness refreshed capacity or reported intent activated control: %+v", session)
			}
			if !slices.Equal(session.PinnedModels, []string{autopilotTestDonor}) || !slices.Equal(session.ResidentModels, []string{autopilotTestDonor}) || session.AlwaysReadyConfigured == nil || !*session.AlwaysReadyConfigured {
				t.Fatalf("stale diagnostic became absent or empty: %+v", session)
			}
		})
	}
}

func TestAutopilotMachineModelsConcurrentHeartbeatProjection(t *testing.T) {
	r, _, now := newAutopilotControllerTestConfig(t, autopilot.DefaultConfig())
	machineID := r.machineID(t, 0)
	p := autopilotMachineProvider(t, r, "provider", machineID, now)
	heartbeat := func(seq uint64) {
		model, minutes := autopilotTestTarget, 0
		if seq%2 == 0 {
			model, minutes = autopilotTestDonor, 60
		}
		state := autopilotControllerState(model)
		state.PinnedModels = []string{model}
		r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
			Status: "idle", IdleUnloadMins: &minutes, ModelAutopilot: state,
			BackendCapacity: autopilotControllerCapacity(seq, model),
		})
	}
	heartbeat(11)
	var writers sync.WaitGroup
	writers.Add(1)
	go func() {
		defer writers.Done()
		for seq := uint64(12); seq < 212; seq++ {
			heartbeat(seq)
		}
	}()
	defer writers.Wait()
	for range 200 {
		session := autopilotMachineStatus(t, r, machineID).Sessions[0]
		if _, err := json.Marshal(session); err != nil {
			t.Fatal(err)
		}
		if len(session.PinnedModels) != 1 || !slices.Equal(session.PinnedModels, session.ResidentModels) || session.IdleUnloadMins == nil || session.AlwaysReadyConfigured == nil || session.LastHeartbeat == nil || session.CapacityAcceptedAt == nil || !session.LastHeartbeat.Equal(*session.CapacityAcceptedAt) {
			t.Fatalf("mixed or aliased heartbeat projection: %+v", session)
		}
		wantMinutes := 0
		if session.PinnedModels[0] == autopilotTestDonor {
			wantMinutes = 60
		}
		if *session.IdleUnloadMins != wantMinutes || *session.AlwaysReadyConfigured != (wantMinutes == 0) {
			t.Fatalf("pin and idle policy came from different heartbeats: %+v", session)
		}
	}
}
