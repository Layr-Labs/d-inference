package store

import (
	"context"
	"fmt"
	"time"
)

// AccountEarningsWindows aggregates the account's last-24h and last-7d rows in
// one statement bounded to the 7 d window, so it walks
// idx_provider_earnings_account (account_id, created_at DESC) for exactly the
// rows it needs. The dashboard header used to fetch a 5,000-row page and sum
// it in Go, which silently truncated the 7 d figures for any account with
// more than 5,000 rows (most weekly-active accounts in production).
func (s *PostgresStore) AccountEarningsWindows(accountID string, now time.Time) (AccountEarningsWindows, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var w AccountEarningsWindows
	err := s.pool.QueryRow(ctx,
		`SELECT
			count(*) FILTER (WHERE created_at >= $2),
			COALESCE(sum(amount_micro_usd) FILTER (WHERE created_at >= $2), 0),
			count(*),
			COALESCE(sum(amount_micro_usd), 0)
		 FROM provider_earnings
		 WHERE account_id = $1 AND created_at >= $3`,
		accountID, now.Add(-24*time.Hour), now.Add(-7*24*time.Hour),
	).Scan(&w.Last24hJobs, &w.Last24hMicroUSD, &w.Last7dJobs, &w.Last7dMicroUSD)
	if err != nil {
		return AccountEarningsWindows{}, fmt.Errorf("store: account earnings windows: %w", err)
	}
	return w, nil
}

func (s *PostgresStore) GetReputations(ctx context.Context, providerIDs []string) (map[string]*ReputationRecord, error) {
	out := make(map[string]*ReputationRecord, len(providerIDs))
	if len(providerIDs) == 0 {
		return out, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed
		 FROM provider_reputation WHERE provider_id = ANY($1)`, providerIDs,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query reputations: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var rep ReputationRecord
		if err := rows.Scan(
			&id, &rep.TotalJobs, &rep.SuccessfulJobs, &rep.FailedJobs,
			&rep.TotalUptimeSeconds, &rep.AvgResponseTimeMs,
			&rep.ChallengesPassed, &rep.ChallengesFailed,
		); err != nil {
			return nil, fmt.Errorf("store: scan reputation: %w", err)
		}
		out[id] = &rep
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate reputations: %w", err)
	}
	return out, nil
}
