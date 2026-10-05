package residency

import (
	"math"
	"slices"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func SelectVictims(state *protocol.ModelAutopilotState, residents []string, need float64, minDwell time.Duration) ([]string, bool) {
	if state == nil || state.FreeForLoadNoEvictGB == nil || state.MaxModelSlots < 1 {
		return nil, false
	}
	free := *state.FreeForLoadNoEvictGB
	slots := state.MaxModelSlots - len(state.ResidentModels)
	if !capacityvalue.FiniteNonnegative(free) || !capacityvalue.FiniteNonnegative(need) || need <= 0 {
		return nil, false
	}
	if free >= need && slots > 0 {
		return []string{}, true
	}
	ordered := append([]string(nil), residents...)
	byID := make(map[string]int)
	for i, m := range state.ResidentModels {
		if _, exists := byID[m.ModelID]; exists {
			return nil, false
		}
		byID[m.ModelID] = i
	}
	for _, id := range ordered {
		if _, exists := byID[id]; !exists {
			return nil, false
		}
	}
	sort.Slice(ordered, func(i, j int) bool {
		a, b := state.ResidentModels[byID[ordered[i]]].IdleSeconds, state.ResidentModels[byID[ordered[j]]].IdleSeconds
		if a == b {
			return ordered[i] < ordered[j]
		}
		return a > b
	})
	dwell := math.Max(minDwell.Seconds(), float64(state.MinDwellSeconds))
	var victims []string
	for _, id := range ordered {
		m := state.ResidentModels[byID[id]]
		if slices.Contains(state.PinnedModels, id) || m.ResidentSeconds < dwell || m.IdleSeconds < math.Max(1, float64(state.MinIdleSeconds)) {
			continue
		}
		victims = append(victims, id)
		slots++
		// Only actual provider-authoritative reclaim credit, NEVER scanner padding.
		if m.ResidentGB != nil && capacityvalue.FiniteNonnegative(*m.ResidentGB) {
			free += *m.ResidentGB
		}
		if free >= need && slots > 0 {
			return victims, true
		}
	}
	return nil, false
}
