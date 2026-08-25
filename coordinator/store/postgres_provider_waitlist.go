package store

import (
	"context"
	"fmt"
	"time"
)

func (s *PostgresStore) UpsertProviderWaitlistSignup(
	ctx context.Context,
	signup ProviderWaitlistSignup,
) error {
	if err := normalizeAndValidateProviderWaitlistSignup(&signup); err != nil {
		return err
	}
	if signup.SubmittedAt.IsZero() {
		signup.SubmittedAt = time.Now().UTC()
	}

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_waitlist_signups
			(email, chip, memory_gb, gpu_cores, other_machine, submitted_at)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 ON CONFLICT (email) DO UPDATE SET
			chip = EXCLUDED.chip,
			memory_gb = EXCLUDED.memory_gb,
			gpu_cores = EXCLUDED.gpu_cores,
			other_machine = EXCLUDED.other_machine,
			submitted_at = EXCLUDED.submitted_at,
			updated_at = NOW()`,
		signup.Email,
		signup.Chip,
		signup.MemoryGB,
		signup.GPUCores,
		signup.OtherMachine,
		signup.SubmittedAt,
	)
	if err != nil {
		return fmt.Errorf("upsert provider waitlist signup: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListProviderWaitlistSignups(
	ctx context.Context,
	limit int,
) ([]ProviderWaitlistSignup, error) {
	limit = providerWaitlistListLimit(limit)
	rows, err := s.pool.Query(ctx,
		`SELECT email, chip, memory_gb, gpu_cores, other_machine,
		        submitted_at, created_at, updated_at
		   FROM provider_waitlist_signups
		  ORDER BY updated_at DESC, email ASC
		  LIMIT $1`,
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("list provider waitlist signups: %w", err)
	}
	defer rows.Close()

	signups := make([]ProviderWaitlistSignup, 0)
	for rows.Next() {
		var signup ProviderWaitlistSignup
		if err := rows.Scan(
			&signup.Email,
			&signup.Chip,
			&signup.MemoryGB,
			&signup.GPUCores,
			&signup.OtherMachine,
			&signup.SubmittedAt,
			&signup.CreatedAt,
			&signup.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan provider waitlist signup: %w", err)
		}
		signups = append(signups, signup)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate provider waitlist signups: %w", err)
	}
	return signups, nil
}
