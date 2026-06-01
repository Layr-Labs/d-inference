package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) attachEarnings(mp *myProvider) {
	if mp.AccountID == "" {
		return
	}
	summary, err := s.store.GetAccountEarningsSummary(mp.AccountID)
	if err != nil {
		s.logger.Debug("get account earnings summary failed",
			"provider_id", mp.ID, "account_id", mp.AccountID, "error", err)
		return
	}
	mp.EarningsTotalMicroUSD = summary.TotalMicroUSD
	mp.EarningsCount = summary.Count
	// Earnings table is the source of truth — every billed request is recorded
	// here. Live lifetime counters in the providers table can drift
	// (heartbeat-driven, lost on restart). Use earnings totals when they
	// exceed the live counter so the dashboard never shows 0/483 for a
	// machine that's served real work.
	if summary.Count > mp.LifetimeRequestsServed {
		mp.LifetimeRequestsServed = summary.Count
	}
	totalTokens := summary.PromptTokens + summary.CompletionTokens
	if totalTokens > mp.LifetimeTokensGenerated {
		mp.LifetimeTokensGenerated = totalTokens
	}
}

func (s *Server) attachStoredReputation(ctx context.Context, mp *myProvider) {
	if mp.ID == "" || mp.Reputation.TotalJobs > 0 || mp.Reputation.ChallengesPassed > 0 || mp.Reputation.ChallengesFailed > 0 {
		return
	}
	rep, err := s.store.GetReputation(ctx, mp.ID)
	if err != nil || rep == nil {
		return
	}
	r := registry.NewReputation()
	r.TotalJobs = rep.TotalJobs
	r.SuccessfulJobs = rep.SuccessfulJobs
	r.FailedJobs = rep.FailedJobs
	r.TotalUptime = time.Duration(rep.TotalUptimeSeconds) * time.Second
	r.AvgResponseTime = time.Duration(rep.AvgResponseTimeMs) * time.Millisecond
	r.ChallengesPassed = rep.ChallengesPassed
	r.ChallengesFailed = rep.ChallengesFailed
	mp.Reputation = myReputation{
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
