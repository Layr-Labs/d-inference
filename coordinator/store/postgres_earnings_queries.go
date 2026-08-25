package store

import (
	"context"
	"fmt"
	"time"
)

func (s *PostgresStore) GetAccountEarningsPage(
	accountID string,
	limit int,
	before *ProviderEarningsCursor,
) (ProviderEarningsPage, error) {
	if limit <= 0 {
		return ProviderEarningsPage{Earnings: []ProviderEarning{}}, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var beforeTime any
	var beforeID int64
	if before != nil {
		beforeTime = before.CreatedAt
		beforeID = before.ID
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, account_id, provider_id, provider_key, job_id, model,
		       amount_micro_usd, prompt_tokens, completion_tokens, created_at
		  FROM provider_earnings
		 WHERE account_id = $1
		   AND (
		       $3::timestamptz IS NULL
		       OR (created_at, id) < ($3::timestamptz, $4)
		   )
		 ORDER BY created_at DESC, id DESC
		 LIMIT $2`,
		accountID, limit+1, beforeTime, beforeID,
	)
	if err != nil {
		return ProviderEarningsPage{}, fmt.Errorf("store: query account earnings page: %w", err)
	}
	defer rows.Close()

	earnings := make([]ProviderEarning, 0, limit+1)
	for rows.Next() {
		var earning ProviderEarning
		if err := rows.Scan(
			&earning.ID,
			&earning.AccountID,
			&earning.ProviderID,
			&earning.ProviderKey,
			&earning.JobID,
			&earning.Model,
			&earning.AmountMicroUSD,
			&earning.PromptTokens,
			&earning.CompletionTokens,
			&earning.CreatedAt,
		); err != nil {
			return ProviderEarningsPage{}, fmt.Errorf("store: scan account earnings page: %w", err)
		}
		earnings = append(earnings, earning)
	}
	if err := rows.Err(); err != nil {
		return ProviderEarningsPage{}, fmt.Errorf("store: iterate account earnings page: %w", err)
	}

	page := ProviderEarningsPage{Earnings: earnings}
	if len(earnings) > limit {
		page.Earnings = earnings[:limit]
		last := page.Earnings[len(page.Earnings)-1]
		page.Next = &ProviderEarningsCursor{CreatedAt: last.CreatedAt, ID: last.ID}
	}
	return page, nil
}

func (s *PostgresStore) GetAccountEarningsWindows(
	accountID string,
	cutoff24h, cutoff7d time.Time,
) (ProviderEarningsWindows, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var windows ProviderEarningsWindows
	err := s.pool.QueryRow(ctx, `
		SELECT
			COALESCE(SUM(amount_micro_usd) FILTER (
				WHERE created_at >= $2
			), 0),
			COUNT(*) FILTER (
				WHERE created_at >= $2 AND model <> 'base_reward'
			),
			COALESCE(SUM(amount_micro_usd) FILTER (
				WHERE created_at >= $3
			), 0),
			COUNT(*) FILTER (
				WHERE created_at >= $3 AND model <> 'base_reward'
			)
		  FROM provider_earnings
		 WHERE account_id = $1
		   AND created_at >= $3`,
		accountID, cutoff24h, cutoff7d,
	).Scan(
		&windows.Last24hMicroUSD,
		&windows.Last24hJobs,
		&windows.Last7dMicroUSD,
		&windows.Last7dJobs,
	)
	if err != nil {
		return ProviderEarningsWindows{}, fmt.Errorf("store: aggregate account earnings windows: %w", err)
	}
	return windows, nil
}
