package accounts

import (
	"context"

	fleetview "github.com/eigeninference/d-inference/coordinator/internal/api/accounts/fleetview"
)

// attachStoredReputations fills in persisted reputation for every machine in
// the fleet that has none from the live registry, with ONE store lookup for
// the whole fleet instead of one per machine (the dashboard polls this every
// 15 s per tab, and the per-machine form was ~78 reputation reads/s in
// production).
func (s *Owner) attachStoredReputations(ctx context.Context, fleet []fleetview.Provider) {
	ids := make([]string, 0, len(fleet))
	for i := range fleet {
		if fleetview.NeedsStoredReputation(&fleet[i]) {
			ids = append(ids, fleet[i].ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	reps, err := s.store.GetReputations(ctx, ids)
	if err != nil {
		return
	}
	for i := range fleet {
		if !fleetview.NeedsStoredReputation(&fleet[i]) {
			continue
		}
		if rep := reps[fleet[i].ID]; rep != nil {
			fleetview.ApplyStoredReputation(&fleet[i], rep)
		}
	}
}
