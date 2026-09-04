package store

import (
	"context"
	"fmt"
	"time"
)

// GetAccountEarningsWindows returns complete dashboard aggregates in one SQL
// query. The account/time index limits the scan to the seven-day window.
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
			COALESCE(SUM(amount_micro_usd), 0),
			COUNT(*) FILTER (
				WHERE model <> 'base_reward'
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
