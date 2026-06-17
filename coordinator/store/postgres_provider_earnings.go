package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// --- Provider Earnings ---

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *PostgresStore) RecordProviderEarning(earning *ProviderEarning) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		earning.AccountID, earning.ProviderID, earning.ProviderKey, earning.JobID,
		earning.Model, earning.AmountMicroUSD, earning.PromptTokens, earning.CompletionTokens,
	)
	if err != nil {
		return fmt.Errorf("store: insert provider earning: %w", err)
	}
	return nil
}

// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
func (s *PostgresStore) GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error) {
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

	var results []ProviderEarning
	for rows.Next() {
		var e ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *PostgresStore) GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error) {
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

	var results []ProviderEarning
	for rows.Next() {
		var e ProviderEarning
		if err := rows.Scan(&e.ID, &e.AccountID, &e.ProviderID, &e.ProviderKey, &e.JobID,
			&e.Model, &e.AmountMicroUSD, &e.PromptTokens, &e.CompletionTokens, &e.CreatedAt); err != nil {
			continue
		}
		results = append(results, e)
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *PostgresStore) GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'provider'`,
		providerKey,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return ProviderEarningsSummary{}, nil
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
// Reads from the materialized earnings_summary table (PK lookup) instead of
// scanning all provider_earnings rows.
func (s *PostgresStore) GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var summary ProviderEarningsSummary
	err := s.pool.QueryRow(ctx,
		`SELECT total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens
		 FROM earnings_summary
		 WHERE key = $1 AND key_type = 'account'`,
		accountID,
	).Scan(&summary.Count, &summary.TotalMicroUSD, &summary.PromptTokens, &summary.CompletionTokens)
	if err != nil {
		// No rows = no earnings yet, return zeros (not an error).
		return ProviderEarningsSummary{}, nil
	}

	return summary, nil
}

// RecordProviderPayout stores a payout record for a provider wallet.
func (s *PostgresStore) RecordProviderPayout(payout *ProviderPayout) error {
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
func (s *PostgresStore) ListProviderPayouts() ([]ProviderPayout, error) {
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

	var results []ProviderPayout
	for rows.Next() {
		var payout ProviderPayout
		if err := rows.Scan(&payout.ID, &payout.ProviderAddress, &payout.AmountMicroUSD, &payout.Model, &payout.JobID, &payout.Settled, &payout.Timestamp); err != nil {
			continue
		}
		results = append(results, payout)
	}
	if results == nil {
		return []ProviderPayout{}, nil
	}

	return results, nil
}

// SettleProviderPayout marks a provider payout as settled.
func (s *PostgresStore) SettleProviderPayout(id int64) error {
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
func (s *PostgresStore) CreditProviderAccount(earning *ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balanceAfter int64
	err := s.pool.QueryRow(ctx, `
		WITH credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			VALUES ($1, $2, $2, NOW())
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + $2,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT $1, $3, $2, balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM credit
		), earning AS (
			INSERT INTO provider_earnings (
				account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
			) VALUES ($1, $6, $7, $4, $8, $2, $9, $10, COALESCE($5::timestamptz, NOW()))
		), summary_account AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			VALUES ($1, 'account', 1, $2, $9, $10, NOW())
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + 1,
			  total_micro_usd = earnings_summary.total_micro_usd + $2,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + $9,
			  total_completion_tokens = earnings_summary.total_completion_tokens + $10,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			VALUES ($7, 'provider', 1, $2, $9, $10, NOW())
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + 1,
			  total_micro_usd = earnings_summary.total_micro_usd + $2,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + $9,
			  total_completion_tokens = earnings_summary.total_completion_tokens + $10,
			  updated_at = NOW()
		)
		SELECT balance_micro_usd FROM credit`,
		earning.AccountID,                    // $1
		earning.AmountMicroUSD,               // $2
		string(LedgerPayout),                 // $3
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
func (s *PostgresStore) CreditProviderWallet(payout *ProviderPayout) error {
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

	if err := creditWithdrawableTx(ctx, tx, payout.ProviderAddress, payout.AmountMicroUSD, LedgerPayout, payout.JobID, payout.Timestamp); err != nil {
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
