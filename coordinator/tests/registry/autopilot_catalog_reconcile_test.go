package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAutopilotTerminalReconcilesActualResidencyAfterCatalogChange(t *testing.T) {
	for _, change := range []string{"removed", "capability"} {
		t.Run(change, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "provider", now, autopilotTestDonor)
			cmd, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now)
			if !ok {
				t.Fatal("reserve failed")
			}
			entries := []production.CatalogEntry{{ID: autopilotTestDonor, SizeGB: 8, MinRAMGB: 16}}
			if change == "capability" {
				entries = append(entries, production.CatalogEntry{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16, RequiredProviderCapabilities: []string{"apple_m5"}})
			}
			r.SetModelCatalog(entries)
			state := autopilotControllerState(autopilotTestTarget, autopilotTestDonor)
			state.LastCommandID, state.LastCommandStatus = cmd.CommandID, protocol.LoadModelStatusSucceeded
			raw := autopilotControllerCapacity(11, autopilotTestTarget, autopilotTestDonor)
			r.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: raw, ModelAutopilot: state, WarmModels: []string{autopilotTestTarget, autopilotTestDonor}})
			p.Mu().Lock()
			defer p.Mu().Unlock()
			_, pending := r.states[p.ID].PrepareDelivery()
			if pending || r.states[p.ID].Transition(p.ModelAutopilot) {
				t.Fatal("catalog filtering stranded terminal ownership")
			}
			if len(p.BackendCapacity.Slots) != 1 || p.BackendCapacity.Slots[0].Model != autopilotTestDonor {
				t.Fatalf("revoked capacity entered routing: %+v", p.BackendCapacity.Slots)
			}
			if len(raw.Slots) != 2 {
				t.Fatal("heartbeat input was mutated")
			}
		})
	}
}

func TestAutopilotTerminalRejectsUnsequencedOrUnboundedRawEvidence(t *testing.T) {
	for _, invalid := range []string{"legacy", "oversized", "unknown resident"} {
		t.Run(invalid, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "provider", now)
			cmd, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now)
			if !ok {
				t.Fatal("reserve failed")
			}
			r.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: autopilotControllerState()})
			state := autopilotControllerState(autopilotTestTarget)
			state.LastCommandID, state.LastCommandStatus = cmd.CommandID, protocol.LoadModelStatusSucceeded
			raw := autopilotControllerCapacity(12, autopilotTestTarget)
			switch invalid {
			case "legacy":
				raw.CapacitySeq = 0
			case "oversized":
				for len(raw.Slots) < 33 {
					raw.Slots = append(raw.Slots, protocol.BackendSlotCapacity{Model: "extra", State: "idle_shutdown"})
				}
			case "unknown resident":
				state = autopilotControllerState(autopilotTestTarget, "unexpected")
				state.LastCommandID, state.LastCommandStatus = cmd.CommandID, protocol.LoadModelStatusSucceeded
				raw = autopilotControllerCapacity(12, autopilotTestTarget, "unexpected")
			}
			r.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: raw, ModelAutopilot: state})
			p.Mu().Lock()
			_, pending := r.states[p.ID].PrepareDelivery()
			p.Mu().Unlock()
			if !pending {
				t.Fatal("invalid raw evidence released command ownership")
			}
		})
	}
}
