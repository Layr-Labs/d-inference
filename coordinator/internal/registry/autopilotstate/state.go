// Package autopilotstate owns a provider session's Autopilot command and lease
// authority. The registry serializes operations with its existing provider lock.
package autopilotstate

import (
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type State struct {
	Inventory
	pending         *pendingCommand
	lease           Lease
	configuredLease *Lease
	backoffUntil    time.Time
}

func New(lease *Lease) *State { return &State{configuredLease: lease} }

func (s *State) control() *Lease {
	if s == nil {
		return nil
	}
	if s.configuredLease != nil {
		return s.configuredLease
	}
	return &s.lease
}

func Consented(state *protocol.ModelAutopilotState) bool {
	return state != nil && state.Protocol == protocol.ModelAutopilotProtocol && state.Enabled &&
		state.CachedOnly && state.Revision != "" && len(state.Revision) <= 64 &&
		len(state.SelectedModels) > 0 && len(state.SelectedModels) <= 256
}

func Allows(state *protocol.ModelAutopilotState, model string) bool {
	return Consented(state) && slices.Contains(state.SelectedModels, model)
}

func (s *State) ControlActive(state *protocol.ModelAutopilotState, session string, now time.Time) bool {
	return s.control().Active(state, session, now)
}

func (s *State) Managed(state *protocol.ModelAutopilotState, session string, now time.Time) bool {
	return Consented(state) && (state.Paused || s.ControlActive(state, session, now))
}

func (s *State) hasPending() bool { return s != nil && s.pending != nil }

func (s *State) Transition(state *protocol.ModelAutopilotState) bool {
	return s.hasPending() || (state != nil && state.ActiveCommandID != "")
}

// AcceptControl records only a successfully enqueued grant for the still-current
// selection. A rejected enqueue must leave the previous expiry unchanged.
func (s *State) AcceptControl(state *protocol.ModelAutopilotState, control protocol.ModelAutopilotControl) {
	s.control().Accept(state, control)
}

// Placement is the command-owned portion of the planner's current node evidence.
// Future residents are creditable only while the operation remains bounded and
// certain; this never changes the provider's actual serving slots.
type Placement struct {
	Pending         bool
	Uncertain       bool
	Available       bool
	FutureResidents []string
}

func (s *State) Placement(state *protocol.ModelAutopilotState, now time.Time, watchdog time.Duration) Placement {
	result := Placement{Pending: s.Transition(state), Available: s == nil || !now.Before(s.backoffUntil)}
	if !s.hasPending() {
		return result
	}
	pending := s.pending
	result.Uncertain = pending.uncertain
	if !pending.uncertain && pending.status != protocol.LoadModelStatusFailed && now.Sub(pending.sentAt) <= watchdog {
		result.FutureResidents = []string{}
		for _, model := range pending.command.ExpectedResidentModels {
			if !slices.Contains(pending.command.UnloadModelIDs, model) {
				result.FutureResidents = append(result.FutureResidents, model)
			}
		}
		if pending.command.LoadModelID != "" {
			result.FutureResidents = append(result.FutureResidents, pending.command.LoadModelID)
		}
	}
	return result
}
