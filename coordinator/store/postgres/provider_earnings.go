package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *PostgresStore) RecordProviderEarning(earning *store.ProviderEarning) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	createdAt := earning.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now()
	}

	_, err := s.pool.Exec(ctx,
		`WITH earning AS (INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		 ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
		 RETURNING account_id, model, amount_micro_usd, prompt_tokens, completion_tokens
		)
		INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, total_base_reward_micro_usd, updated_at)
		SELECT account_id, 'account', CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END, amount_micro_usd,
		 CASE WHEN model = 'base_reward' THEN 0 ELSE prompt_tokens END,
		 CASE WHEN model = 'base_reward' THEN 0 ELSE completion_tokens END,
		 CASE WHEN model = 'base_reward' THEN amount_micro_usd ELSE 0 END, NOW() FROM earning WHERE account_id <> ''
		ON CONFLICT (key, key_type) DO UPDATE SET
		 total_count = earnings_summary.total_count + EXCLUDED.total_count,
		 total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
		 total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
		 total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
		 total_base_reward_micro_usd = earnings_summary.total_base_reward_micro_usd + EXCLUDED.total_base_reward_micro_usd,
		 updated_at = NOW()`,
		earning.AccountID, earning.ProviderID, earning.ProviderKey, earning.JobID,
		earning.Model, earning.AmountMicroUSD, earning.PromptTokens, earning.CompletionTokens,
		createdAt,
	)
	if err != nil {
		return fmt.Errorf("store: insert provider earning: %w", err)
	}
	return nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *PostgresStore) GetAccountEarnings(accountID string, limit int) ([]store.ProviderEarning, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
		 FROM provider_earnings
		 WHERE account_id = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		accountID, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query account earnings: %w", err)
	}
	defer rows.Close()

	var results []store.ProviderEarning
	for rows.Next() {
		var e store.ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []store.ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *PostgresStore) GetAccountEarningsSummary(accountID string) (store.ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary store.ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, total_base_reward_micro_usd
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'account'`,
		accountID,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens, &summary.BaseRewardMicroUSD)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return store.ProviderEarningsSummary{}, nil
	}

	return summary, nil
}

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
//
// Single-statement CTE: upsert balance, insert ledger entry, insert earning --
// all in one round trip. The old implementation used 6 sequential round trips
// (BEGIN + upsert + SELECT balance + INSERT ledger + INSERT earning + COMMIT).
func (s *PostgresStore) CreditProviderAccount(earning *store.ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return creditProviderAccount(ctx, s.pool, earning)
}
