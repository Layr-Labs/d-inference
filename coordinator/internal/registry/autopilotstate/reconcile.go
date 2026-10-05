package autopilotstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Reconcile runs only after the registry accepts the capacity sequence. Status
// messages alone never release ownership or manufacture warm capacity.
func (s *State) Reconcile(providerID string, state *protocol.ModelAutopilotState, reported *protocol.BackendCapacity, capacitySeq uint64, now time.Time, emit func(store.AutopilotRecord)) bool {
	if !s.hasPending() || state == nil {
		return false
	}
	pending := s.pending
	if capacitySeq <= pending.capacitySeq || state.ActiveCommandID != "" || state.LastCommandID != pending.command.CommandID {
		return false
	}
	if state.LastCommandStatus != protocol.LoadModelStatusSucceeded && state.LastCommandStatus != protocol.LoadModelStatusFailed {
		return false
	}
	// Use the raw sequenced evidence, not the catalog-filtered serving projection.
	if reported == nil || reported.CapacitySeq != capacitySeq {
		return false
	}
	actual := autopilot.CloneState(state)
	actual.Enabled = true // opt-out can acknowledge an accepted operation
	allowed := make(map[string]bool)
	for _, model := range pending.command.ExpectedResidentModels {
		allowed[model] = true
	}
	if pending.command.LoadModelID != "" {
		allowed[pending.command.LoadModelID] = true
	}
	for _, resident := range actual.ResidentModels {
		if !allowed[resident.ModelID] {
			return false
		}
	}
	if !autopilot.StateMatchesCapacity(actual, reported, capacitySeq) {
		return false
	}
	if state.LastCommandStatus == protocol.LoadModelStatusFailed {
		backoff := pending.failureBackoff
		if backoff <= 0 {
			backoff = 2 * time.Minute
		}
		s.backoffUntil = now.Add(backoff)
	}
	emit(store.AutopilotRecord{CommandID: pending.command.CommandID, At: now, ProviderID: providerID, Phase: state.LastCommandStatus,
		Load: pending.command.LoadModelID, Unload: pending.command.UnloadModelIDs, Before: pending.command.ExpectedResidentModels,
		After: autopilot.ResidentIDs(state), ElapsedMS: now.Sub(pending.sentAt).Milliseconds(), LoadMS: max(0, min(state.LastLoadMS, 1800000)), ReleaseMS: max(0, min(state.LastReleaseMS, 1800000))})
	s.pending = nil
	return true
}

// ReportedCapacity retains bounded wire evidence only when a command needs
// terminal reconciliation, before catalog filtering removes revoked slots.
func (s *State) ReportedCapacity(reported *protocol.BackendCapacity) *protocol.BackendCapacity {
	if !s.hasPending() {
		return nil
	}
	return autopilot.CloneReportedCapacity(reported)
}
