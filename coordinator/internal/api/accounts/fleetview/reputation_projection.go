package fleetview

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

func NeedsStoredReputation(mp *Provider) bool {
	return mp.ID != "" && mp.Reputation.TotalJobs == 0 && mp.Reputation.ChallengesPassed == 0 && mp.Reputation.ChallengesFailed == 0
}

func ApplyStoredReputation(mp *Provider, rep *store.ReputationRecord) {
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
