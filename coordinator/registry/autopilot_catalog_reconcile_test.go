package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAutopilotTerminalReconcilesActualResidencyAfterCatalogChange(t *testing.T) {
	for _, change := range []string{"removed", "capability"} {
		t.Run(change, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "provider", now, autopilotTestDonor)
			cmd, ok := r.reserveAutopilotAction(c, autopilotControllerPlan(t, r, c, now), now)
			if !ok {
				t.Fatal("reserve failed")
			}
			entries := []CatalogEntry{{ID: autopilotTestDonor, SizeGB: 8, MinRAMGB: 16}}
			if change == "capability" {
				entries = append(entries, CatalogEntry{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16, RequiredProviderCapabilities: []string{"apple_m5"}})
			}
			r.SetModelCatalog(entries)
			state := autopilotControllerState(autopilotTestTarget, autopilotTestDonor)
			state.LastCommandID, state.LastCommandStatus = cmd.CommandID, protocol.LoadModelStatusSucceeded
			raw := autopilotControllerCapacity(11, autopilotTestTarget, autopilotTestDonor)
			r.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: raw, ModelAutopilot: state, WarmModels: []string{autopilotTestTarget, autopilotTestDonor}})
			p.mu.Lock()
			defer p.mu.Unlock()
			if p.autopilotPending != nil || providerAutopilotTransitionLocked(p) {
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
			cmd, ok := r.reserveAutopilotAction(c, autopilotControllerPlan(t, r, c, now), now)
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
			p.mu.Lock()
			pending := p.autopilotPending != nil
			p.mu.Unlock()
			if !pending {
				t.Fatal("invalid raw evidence released command ownership")
			}
		})
	}
}
