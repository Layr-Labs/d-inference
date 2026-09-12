package registry

import "time"

// allocateWarmPoolLoads fills a model's bounded load allowance from the whole
// eligible shortlist. Fleet snapshots overlap across models: a machine claimed
// earlier in this planning pass must not consume another model's allowance.
// Reservation can also lose a race to a heartbeat-triggered load, so rejected
// candidates are replaced from the remaining shortlist without rescanning it.
// The observe-only path applies the same per-provider exclusivity locally.
func allocateWarmPoolLoads(
	model string,
	candidates []warmPoolCandidate,
	need int,
	assigned map[string]struct{},
	reserve func([]modelLoadAction, time.Time) []modelLoadAction,
	now time.Time,
) []modelLoadAction {
	if need <= 0 {
		return nil
	}
	actions := make([]modelLoadAction, 0, need)
	for cursor := 0; cursor < len(candidates) && len(actions) < need; {
		remaining := need - len(actions)
		batch := make([]modelLoadAction, 0, remaining)
		for cursor < len(candidates) && len(batch) < remaining {
			candidate := candidates[cursor]
			cursor++
			if _, used := assigned[candidate.providerID]; used {
				continue
			}
			batch = append(batch, modelLoadAction{providerID: candidate.providerID, modelID: model})
		}
		if len(batch) == 0 {
			break
		}
		if reserve != nil {
			batch = reserve(batch, now)
		}
		for _, action := range batch {
			assigned[action.providerID] = struct{}{}
			actions = append(actions, action)
		}
	}
	return actions
}
