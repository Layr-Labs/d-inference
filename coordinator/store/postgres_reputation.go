package store

import (
	"context"
	"fmt"
	"time"
)

// --- Provider Reputation Persistence ---

func (s *PostgresStore) UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_reputation (
			provider_id, total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed, updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
		ON CONFLICT (provider_id) DO UPDATE SET
			total_jobs = $2, successful_jobs = $3, failed_jobs = $4,
			total_uptime_seconds = $5, avg_response_time_ms = $6,
			challenges_passed = $7, challenges_failed = $8,
			updated_at = NOW()`,
		providerID, rep.TotalJobs, rep.SuccessfulJobs, rep.FailedJobs,
		rep.TotalUptimeSeconds, rep.AvgResponseTimeMs,
		rep.ChallengesPassed, rep.ChallengesFailed,
	)
	if err != nil {
		return fmt.Errorf("store: upsert reputation: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetReputation(ctx context.Context, providerID string) (*ReputationRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rep ReputationRecord
	err := s.pool.QueryRow(ctx,
		`SELECT total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed
		 FROM provider_reputation WHERE provider_id = $1`, providerID,
	).Scan(
		&rep.TotalJobs, &rep.SuccessfulJobs, &rep.FailedJobs,
		&rep.TotalUptimeSeconds, &rep.AvgResponseTimeMs,
		&rep.ChallengesPassed, &rep.ChallengesFailed,
	)
	if err != nil {
		return nil, fmt.Errorf("store: reputation not found: %w", err)
	}
	return &rep, nil
}
