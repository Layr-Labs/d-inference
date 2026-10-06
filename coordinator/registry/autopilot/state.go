package autopilot

import (
	"math"
	"slices"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func CloneState(in *protocol.ModelAutopilotState) *protocol.ModelAutopilotState {
	if in == nil {
		return nil
	}
	// Keep malformed opt-in/control ownership fail-closed without retaining an
	// unbounded untrusted report. A later valid heartbeat can replace it.
	if len(in.SelectedModels) > 256 || len(in.Revision) > 64 || len(in.SessionID) > 128 || len(in.LoadHistory) > 64 || len(in.ResidentModels) > 32 || len(in.PinnedModels) > 256 || len(in.ActiveCommandID) > 64 || len(in.LastCommandID) > 64 {
		return &protocol.ModelAutopilotState{Protocol: in.Protocol, Enabled: in.Enabled, ActiveCommandID: "invalid_report"}
	}
	for _, id := range in.SelectedModels {
		if id == "" || len(id) > 256 {
			return &protocol.ModelAutopilotState{Enabled: in.Enabled, ActiveCommandID: "invalid_report"}
		}
	}
	for _, timing := range in.LoadHistory {
		if len(timing.ModelID) > 256 || len(timing.WeightHash) > 128 {
			return &protocol.ModelAutopilotState{Enabled: in.Enabled, ActiveCommandID: "invalid_report"}
		}
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
	out.SelectedModels = append([]string(nil), in.SelectedModels...)
	out.LoadHistory = append([]protocol.ModelAutopilotLoadTiming(nil), in.LoadHistory...)
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

func validState(s *protocol.ModelAutopilotState) bool {
	if s == nil || s.Protocol != protocol.ModelAutopilotProtocol || !s.Enabled || !s.CachedOnly || s.MaxModelSlots < 1 || s.MaxModelSlots > 32 || s.MinDwellSeconds < 0 || s.MinDwellSeconds > 86400 || len(s.ResidentModels) > 32 || len(s.PinnedModels) > 256 {
		return false
	}
	if len(s.ActiveCommandID) > 64 || len(s.LastCommandID) > 64 {
		return false
	}
	if s.FreeForLoadNoEvictGB == nil || !finiteNonnegative(*s.FreeForLoadNoEvictGB) || *s.FreeForLoadNoEvictGB > 4096 {
		return false
	}
	seen := make(map[string]bool)
	for _, m := range s.ResidentModels {
		if m.ModelID == "" || len(m.ModelID) > 256 || seen[m.ModelID] || !finiteNonnegative(m.ResidentSeconds) || !finiteNonnegative(m.IdleSeconds) || !finiteNonnegative(m.WeightsGB) {
			return false
		}
		if m.ResidentGB != nil && (!finiteNonnegative(*m.ResidentGB) || *m.ResidentGB > 4096) {
			return false
		}
		seen[m.ModelID] = true
	}
	return true
}
func finiteNonnegative(v float64) bool { return v >= 0 && !math.IsNaN(v) && !math.IsInf(v, 0) }

func ResidentIDs(s *protocol.ModelAutopilotState) []string {
	out := []string{}
	if s != nil {
		for _, m := range s.ResidentModels {
			out = append(out, m.ModelID)
		}
	}
	sort.Strings(out)
	return out
}

func SortedStrings(values []string) []string {
	out := append([]string(nil), values...)
	slices.Sort(out)
	return out
}

func StateMatchesCapacity(state *protocol.ModelAutopilotState, capacity *protocol.BackendCapacity, sequence uint64) bool {
	if capacity == nil || sequence == 0 || !validState(state) {
		return false
	}
	residents := make(map[string]bool)
	for _, m := range state.ResidentModels {
		residents[m.ModelID] = true
	}
	for _, slot := range capacity.Slots {
		if slot.State == "running" || slot.State == "idle" {
			if !residents[slot.Model] {
				return false
			}
			delete(residents, slot.Model)
		}
	}
	return len(residents) == 0
}

// CloneReportedCapacity keeps only bounded residency/sequence evidence. It is
// separate from catalog-filtered routing capacity and never supplies budgets.
func CloneReportedCapacity(in *protocol.BackendCapacity) *protocol.BackendCapacity {
	if in == nil || len(in.Slots) > 32 {
		return nil
	}
	out := &protocol.BackendCapacity{CapacitySeq: in.CapacitySeq}
	for _, slot := range in.Slots {
		if slot.Model == "" || len(slot.Model) > 256 || len(slot.State) > 32 {
			return nil
		}
		out.Slots = append(out.Slots, protocol.BackendSlotCapacity{Model: slot.Model, State: slot.State})
	}
	return out
}
