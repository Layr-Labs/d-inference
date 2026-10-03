package accounts

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// attachStoredReputations fills in persisted reputation for every machine in
// the fleet that has none from the live registry, with ONE store lookup for
// the whole fleet instead of one per machine (the dashboard polls this every
// 15 s per tab, and the per-machine form was ~78 reputation reads/s in
// production).
func (s *Owner) attachStoredReputations(ctx context.Context, fleet []myProvider) {
	ids := make([]string, 0, len(fleet))
	for i := range fleet {
		if needsStoredReputation(&fleet[i]) {
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
		if !needsStoredReputation(&fleet[i]) {
			continue
		}
		if rep := reps[fleet[i].ID]; rep != nil {
			applyStoredReputation(&fleet[i], rep)
		}
	}
}

func needsStoredReputation(mp *myProvider) bool {
	return mp.ID != "" && mp.Reputation.TotalJobs == 0 && mp.Reputation.ChallengesPassed == 0 && mp.Reputation.ChallengesFailed == 0
}

func applyStoredReputation(mp *myProvider, rep *store.ReputationRecord) {
	mp.Reputation = myReputation{
		TotalJobs:          rep.TotalJobs,
		SuccessfulJobs:     rep.SuccessfulJobs,
		FailedJobs:         rep.FailedJobs,
		TotalUptimeSeconds: rep.TotalUptimeSeconds,
		AvgResponseTimeMs:  rep.AvgResponseTimeMs,
		ChallengesPassed:   rep.ChallengesPassed,
		ChallengesFailed:   rep.ChallengesFailed,
	}
}
