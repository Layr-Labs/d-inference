package registry

import (
	"math"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func providerAutopilotManagedLocked(p *Provider) bool {
	return p.ModelAutopilot != nil && p.ModelAutopilot.Enabled
}
func providerAutopilotTransitionLocked(p *Provider) bool {
	return p.autopilotPending != nil || (p.ModelAutopilot != nil && p.ModelAutopilot.ActiveCommandID != "")
}

func cloneAutopilotState(in *protocol.ModelAutopilotState) *protocol.ModelAutopilotState {
	if in == nil {
		return nil
	}
	// Keep malformed opt-in/control ownership fail-closed without retaining an
	// unbounded untrusted report. A later valid heartbeat can replace it.
	if len(in.ResidentModels) > 32 || len(in.PinnedModels) > 256 || len(in.ActiveCommandID) > 64 || len(in.LastCommandID) > 64 {
		return &protocol.ModelAutopilotState{Protocol: in.Protocol, Enabled: in.Enabled, ActiveCommandID: "invalid_report"}
	}
	for _, m := range in.ResidentModels {
		if len(m.ModelID) > 256 {
			return &protocol.ModelAutopilotState{Protocol: in.Protocol, Enabled: in.Enabled, ActiveCommandID: "invalid_report"}
		}
	}
	for _, m := range in.PinnedModels {
		if len(m) > 256 {
			return &protocol.ModelAutopilotState{Protocol: in.Protocol, Enabled: in.Enabled, ActiveCommandID: "invalid_report"}
		}
	}
	out := *in
	out.PinnedModels = append([]string(nil), in.PinnedModels...)
	out.ResidentModels = append([]protocol.ModelAutopilotResident(nil), in.ResidentModels...)
	if in.FreeForLoadNoEvictGB != nil {
		v := *in.FreeForLoadNoEvictGB
		out.FreeForLoadNoEvictGB = &v
	}
	for i := range out.ResidentModels {
		if in.ResidentModels[i].ResidentGB != nil {
			v := *in.ResidentModels[i].ResidentGB
			out.ResidentModels[i].ResidentGB = &v
		}
	}
	return &out
}

func validAutopilotState(s *protocol.ModelAutopilotState) bool {
	if s == nil || s.Protocol != protocol.ModelAutopilotProtocol || !s.Enabled || !s.CachedOnly || s.MaxModelSlots < 1 || s.MaxModelSlots > 32 || s.MinDwellSeconds < 0 || s.MinDwellSeconds > 86400 || len(s.ResidentModels) > 32 || len(s.PinnedModels) > 256 {
		return false
	}
	if len(s.ActiveCommandID) > 64 || len(s.LastCommandID) > 64 {
		return false
	}
	if s.FreeForLoadNoEvictGB == nil || !finiteAutopilotNonnegative(*s.FreeForLoadNoEvictGB) || *s.FreeForLoadNoEvictGB > 4096 {
		return false
	}
	seen := make(map[string]bool)
	for _, m := range s.ResidentModels {
		if m.ModelID == "" || len(m.ModelID) > 256 || seen[m.ModelID] || !finiteAutopilotNonnegative(m.ResidentSeconds) || !finiteAutopilotNonnegative(m.IdleSeconds) || !finiteAutopilotNonnegative(m.WeightsGB) {
			return false
		}
		if m.ResidentGB != nil && (!finiteAutopilotNonnegative(*m.ResidentGB) || *m.ResidentGB > 4096) {
			return false
		}
		seen[m.ModelID] = true
	}
	return true
}
func finiteAutopilotNonnegative(v float64) bool { return v >= 0 && !math.IsNaN(v) && !math.IsInf(v, 0) }

func autopilotResidentIDs(s *protocol.ModelAutopilotState) []string {
	out := []string{}
	if s != nil {
		for _, m := range s.ResidentModels {
			out = append(out, m.ModelID)
		}
	}
	sort.Strings(out)
	return out
}

func autopilotStateMatchesCapacity(p *Provider) bool {
	if p.BackendCapacity == nil || p.capacitySeq == 0 || !validAutopilotState(p.ModelAutopilot) {
		return false
	}
	residents := make(map[string]bool)
	for _, m := range p.ModelAutopilot.ResidentModels {
		residents[m.ModelID] = true
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.State == "running" || slot.State == "idle" {
			if !residents[slot.Model] {
				return false
			}
			delete(residents, slot.Model)
		}
	}
	return len(residents) == 0
}

// Called only after the accepted capacity-sequence gate, under p.mu. Status
// messages alone never clear reservations or manufacture warm slot capacity.
func (r *Registry) reconcileAutopilotHeartbeatLocked(p *Provider, state *protocol.ModelAutopilotState, now time.Time) {
	p.ModelAutopilot = cloneAutopilotState(state)
	pending := p.autopilotPending
	if pending == nil || state == nil || p.capacitySeq <= pending.CapacitySeq || state.ActiveCommandID != "" || state.LastCommandID != pending.Command.CommandID {
		return
	}
	if state.LastCommandStatus != protocol.LoadModelStatusSucceeded && state.LastCommandStatus != protocol.LoadModelStatusFailed {
		return
	}
	// A disabled report can acknowledge opt-out completion; its resident list
	// must still exactly match the same accepted backend snapshot.
	enabled := state.Enabled
	if !enabled {
		copy := cloneAutopilotState(state)
		copy.Enabled = true
		p.ModelAutopilot = copy
	}
	matches := autopilotStateMatchesCapacity(p)
	p.ModelAutopilot = cloneAutopilotState(state)
	if !matches {
		return
	}
	if state.LastCommandStatus == protocol.LoadModelStatusFailed {
		backoff := pending.FailureBackoff
		if backoff <= 0 {
			backoff = 2 * time.Minute
		}
		p.autopilotBackoffUntil = now.Add(backoff)
	}
	p.autopilotPending = nil
}
