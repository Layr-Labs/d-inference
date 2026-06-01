package store

import "context"

// ReputationStore covers persistence of provider reputation records.
type ReputationStore interface {
	// UpsertReputation creates or updates a provider's reputation record.
	UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error

	// GetReputation returns a provider's reputation record.
	GetReputation(ctx context.Context, providerID string) (*ReputationRecord, error)
}

// ReputationRecord is the persistent representation of a provider's reputation.
type ReputationRecord struct {
	TotalJobs          int   `json:"total_jobs"`
	SuccessfulJobs     int   `json:"successful_jobs"`
	FailedJobs         int   `json:"failed_jobs"`
	TotalUptimeSeconds int64 `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64 `json:"avg_response_time_ms"`
	ChallengesPassed   int   `json:"challenges_passed"`
	ChallengesFailed   int   `json:"challenges_failed"`
}
