package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	providerCreditAttemptTimeout = 5 * time.Second
	providerCreditMaxAttempts    = 3
	providerCreditRetryBackoff   = 50 * time.Millisecond
)

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning. Each attempt is one SQL statement, and
// job_id is its idempotency key, so retrying an ambiguous timeout cannot credit
// the account twice.
//
// A bounded per-attempt timeout keeps a blocked connection from occupying the
// completion path forever. Retryable lock, serialization, connection, and
// timeout failures get fresh attempts; this is especially important while an
// older coordinator's one-shot earnings-summary repair holds table locks.
func (s *PostgresStore) CreditProviderAccount(earning *ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	var lastErr error
	attempts := 0
	for attempt := 1; attempt <= providerCreditMaxAttempts; attempt++ {
		attempts = attempt
		lastErr = s.creditProviderAccountAttempt(earning)
		if lastErr == nil {
			return nil
		}

		// Retrying an empty job ID is unsafe: the partial unique index deliberately
		// excludes it, so an ambiguous commit could otherwise double-credit.
		if earning.JobID == "" || !retryableProviderCreditError(lastErr) {
			break
		}
		if attempt < providerCreditMaxAttempts {
			time.Sleep(time.Duration(attempt) * providerCreditRetryBackoff)
		}
	}

	return fmt.Errorf(
		"store: credit provider account after %d attempt(s): %w",
		attempts,
		lastErr,
	)
}

func (s *PostgresStore) creditProviderAccountAttempt(earning *ProviderEarning) error {
	ctx, cancel := context.WithTimeout(context.Background(), providerCreditAttemptTimeout)
	defer cancel()

	// The earning CTE is the idempotency gate: ON CONFLICT (job_id) DO NOTHING
	// means a retried settlement inserts nothing and RETURNS no row, so every
	// downstream CTE is a pure no-op. The outer COALESCE still returns one row
	// for a duplicate.
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
			SELECT account_id, 'account', CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END,
			       amount_micro_usd, prompt_tokens, completion_tokens, NOW() FROM earning
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + EXCLUDED.total_count,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT provider_key, 'provider', CASE WHEN model = 'base_reward' THEN 0 ELSE 1 END,
			       amount_micro_usd, prompt_tokens, completion_tokens, NOW() FROM earning
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
		string(LedgerPayout),                 // $3
		earning.JobID,                        // $4
		nullableCreatedAt(earning.CreatedAt), // $5
		earning.ProviderID,                   // $6
		earning.ProviderKey,                  // $7
		earning.Model,                        // $8
		earning.PromptTokens,                 // $9
		earning.CompletionTokens,             // $10
	).Scan(&balanceAfter)
	return err
}

func retryableProviderCreditError(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || pgconn.Timeout(err) || pgconn.SafeToRetry(err) {
		return true
	}

	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	switch pgErr.Code {
	case "40001", // serialization_failure
		"40P01", // deadlock_detected
		"55P03", // lock_not_available
		"57014": // query_canceled (statement/lock timeout)
		return true
	default:
		return len(pgErr.Code) >= 2 && pgErr.Code[:2] == "08" // connection_exception class
	}
}
