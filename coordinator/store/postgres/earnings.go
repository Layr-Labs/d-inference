package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *Store) RecordProviderEarning(earning *contracts.ProviderEarning) error {
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
		 RETURNING account_id, provider_key, model, amount_micro_usd, prompt_tokens, completion_tokens
		), summaries AS (
		 SELECT account_id AS key, 'account' AS key_type, model, amount_micro_usd, prompt_tokens, completion_tokens FROM earning WHERE account_id <> ''
		 UNION ALL
		 SELECT provider_key, 'provider', model, amount_micro_usd, prompt_tokens, completion_tokens FROM earning WHERE provider_key <> ''
		)
		INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
		SELECT key, key_type, CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END, amount_micro_usd,
		 CASE WHEN model = 'base_reward' THEN 0 ELSE prompt_tokens END,
		 CASE WHEN model = 'base_reward' THEN 0 ELSE completion_tokens END, NOW() FROM summaries
		ON CONFLICT (key, key_type) DO UPDATE SET
		 total_count = earnings_summary.total_count + EXCLUDED.total_count,
		 total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
		 total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
		 total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
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

// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
func (s *Store) GetProviderEarnings(providerKey string, limit int) ([]contracts.ProviderEarning, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
		 FROM provider_earnings
		 WHERE provider_key = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		providerKey, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query provider earnings: %w", err)
	}
	defer rows.Close()

	var results []contracts.ProviderEarning
	for rows.Next() {
		var e contracts.ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []contracts.ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *Store) GetAccountEarnings(accountID string, limit int) ([]contracts.ProviderEarning, error) {
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

	var results []contracts.ProviderEarning
	for rows.Next() {
		var e contracts.ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []contracts.ProviderEarning{}, nil
	}
	return results, nil
}

// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *Store) GetProviderEarningsSummary(providerKey string) (contracts.ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary contracts.ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'provider'`,
		providerKey,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return contracts.ProviderEarningsSummary{}, nil
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *Store) GetAccountEarningsSummary(accountID string) (contracts.ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary contracts.ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'account'`,
		accountID,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return contracts.ProviderEarningsSummary{}, nil
	}

	return summary, nil
}

// RecordProviderPayout stores a payout record for a provider wallet.
func (s *Store) RecordProviderPayout(payout *contracts.ProviderPayout) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_payouts (provider_address, amount_micro_usd, model, job_id, settled, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		payout.ProviderAddress, payout.AmountMicroUSD, payout.Model, payout.JobID, payout.Settled, nullableCreatedAt(payout.Timestamp),
	)
	if err != nil {
		return fmt.Errorf("store: insert provider payout: %w", err)
	}

	return nil
}

// ListProviderPayouts returns all provider payout records in creation order.
func (s *Store) ListProviderPayouts() ([]contracts.ProviderPayout, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, provider_address, amount_micro_usd, model, job_id, settled, created_at
		 FROM provider_payouts
		 ORDER BY id ASC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: query provider payouts: %w", err)
	}
	defer rows.Close()

	var results []contracts.ProviderPayout
	for rows.Next() {
		var payout contracts.ProviderPayout
		if err := rows.Scan(&payout.ID, &payout.ProviderAddress, &payout.AmountMicroUSD, &payout.Model, &payout.JobID, &payout.Settled, &payout.Timestamp); err != nil {
			continue
		}
		results = append(results, payout)
	}
	if results == nil {
		return []contracts.ProviderPayout{}, nil
	}

	return results, nil
}

// SettleProviderPayout marks a provider payout as settled.
func (s *Store) SettleProviderPayout(id int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_payouts
		 SET settled = TRUE
		 WHERE id = $1 AND settled = FALSE`,
		id,
	)
	if err != nil {
		return fmt.Errorf("store: settle provider payout: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("provider payout %d not found or already settled", id)
	}

	return nil
}

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
//
// Single-statement CTE: upsert balance, insert ledger entry, insert earning --
// all in one round trip. The old implementation used 6 sequential round trips
// (BEGIN + upsert + SELECT balance + INSERT ledger + INSERT earning + COMMIT).
func (s *Store) CreditProviderAccount(earning *contracts.ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// The earning CTE is the idempotency gate: ON CONFLICT (job_id) DO NOTHING
	// means a retried settlement (same job_id) inserts nothing and RETURNS no
	// row, so every downstream CTE (which selects FROM earning) is a pure no-op
	// — no balance bump, no ledger row, no summary bump. The outer COALESCE keeps
	// the query returning exactly one row even on a duplicate.
	var balanceAfter int64
	err := s.pool.QueryRow(ctx, `
		WITH earning AS (
			INSERT INTO provider_earnings (
				account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
			) VALUES ($1, $6, $7, $4, $8, $2, $9, $10, COALESCE($5::timestamptz, NOW()))
			ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
			RETURNING account_id, provider_key, model, amount_micro_usd, prompt_tokens, completion_tokens
		), credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			SELECT account_id, amount_micro_usd, amount_micro_usd, NOW() FROM earning
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT e.account_id, $3, e.amount_micro_usd, c.balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM earning e CROSS JOIN credit c
		), summary_account AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT account_id, 'account', CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END, amount_micro_usd,
			 CASE WHEN model = 'base_reward' THEN 0 ELSE prompt_tokens END,
			 CASE WHEN model = 'base_reward' THEN 0 ELSE completion_tokens END, NOW() FROM earning
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + EXCLUDED.total_count,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT provider_key, 'provider', CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END, amount_micro_usd,
			 CASE WHEN model = 'base_reward' THEN 0 ELSE prompt_tokens END,
			 CASE WHEN model = 'base_reward' THEN 0 ELSE completion_tokens END, NOW() FROM earning
			WHERE provider_key <> ''
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + EXCLUDED.total_count,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		)
		SELECT COALESCE((SELECT balance_micro_usd FROM credit), 0)`,
		earning.AccountID,                    // $1
		earning.AmountMicroUSD,               // $2
		string(contracts.LedgerPayout),       // $3
		earning.JobID,                        // $4
		nullableCreatedAt(earning.CreatedAt), // $5
		earning.ProviderID,                   // $6
		earning.ProviderKey,                  // $7
		earning.Model,                        // $8
		earning.PromptTokens,                 // $9
		earning.CompletionTokens,             // $10
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: credit provider account: %w", err)
	}
	return nil
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *Store) CreditProviderWallet(payout *contracts.ProviderPayout) error {
	if payout == nil {
		return errors.New("provider payout is required")
	}
	if payout.ProviderAddress == "" {
		return errors.New("provider payout address is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditWithdrawableBalance(ctx, tx, payout.ProviderAddress, payout.AmountMicroUSD, contracts.LedgerPayout, payout.JobID, payout.Timestamp); err != nil {
		return err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO provider_payouts (provider_address, amount_micro_usd, model, job_id, settled, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		payout.ProviderAddress,
		payout.AmountMicroUSD,
		payout.Model,
		payout.JobID,
		payout.Settled,
		nullableCreatedAt(payout.Timestamp),
	)
	if err != nil {
		return fmt.Errorf("store: insert provider payout: %w", err)
	}

	return tx.Commit(ctx)
}
