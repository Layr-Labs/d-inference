package accountfleet

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// reputationView is the wire shape for a provider's reputation snapshot.
type reputationView struct {
	Score              float64 `json:"score"`
	TotalJobs          int     `json:"total_jobs"`
	SuccessfulJobs     int     `json:"successful_jobs"`
	FailedJobs         int     `json:"failed_jobs"`
	TotalUptimeSeconds int64   `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64   `json:"avg_response_time_ms"`
	ChallengesPassed   int     `json:"challenges_passed"`
	ChallengesFailed   int     `json:"challenges_failed"`
}

// attachStoredReputations fills in persisted reputation for every machine in
// the fleet that has none from the live registry, with ONE store lookup for
// the whole fleet instead of one per machine (the dashboard polls this every
// 15 s per tab, and the per-machine form was ~78 reputation reads/s in
// production).
func (s *Controller) attachStoredReputations(ctx context.Context, fleet []providerView) {
	ids := make([]string, 0, len(fleet))
	for i := range fleet {
		if needsStoredReputation(&fleet[i]) {
			ids = append(ids, fleet[i].ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	reps, err := s.store().GetReputations(ctx, ids)
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

func needsStoredReputation(mp *providerView) bool {
	return mp.ID != "" && mp.Reputation.TotalJobs == 0 && mp.Reputation.ChallengesPassed == 0 && mp.Reputation.ChallengesFailed == 0
}

func applyStoredReputation(mp *providerView, rep *store.ReputationRecord) {
	r := registry.NewReputation()
	r.TotalJobs = rep.TotalJobs
	r.SuccessfulJobs = rep.SuccessfulJobs
	r.FailedJobs = rep.FailedJobs
	r.TotalUptime = time.Duration(rep.TotalUptimeSeconds) * time.Second
	r.AvgResponseTime = time.Duration(rep.AvgResponseTimeMs) * time.Millisecond
	r.ChallengesPassed = rep.ChallengesPassed
	r.ChallengesFailed = rep.ChallengesFailed
	mp.Reputation = reputationView{
		Score:              r.Score(),
		TotalJobs:          r.TotalJobs,
		SuccessfulJobs:     r.SuccessfulJobs,
		FailedJobs:         r.FailedJobs,
		TotalUptimeSeconds: int64(r.TotalUptime / time.Second),
		AvgResponseTimeMs:  int64(r.AvgResponseTime / time.Millisecond),
		ChallengesPassed:   r.ChallengesPassed,
		ChallengesFailed:   r.ChallengesFailed,
	}
}
