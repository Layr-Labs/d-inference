package store

import (
	"context"
	"fmt"
	"math"
	"time"
)

// NetworkModelEarningsReader exposes only aggregate settled inference payouts.
// Account identities and base rewards never enter this public projection.
type NetworkModelEarningsReader interface {
	NetworkModelEarnings(context.Context, time.Time, time.Time) (map[string]int64, error)
}

func (s *MemoryStore) NetworkModelEarnings(ctx context.Context, since, until time.Time) (map[string]int64, error) {
	if err := validateInsightWindow(since, until); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := map[string]int64{}
	for _, e := range s.providerEarnings {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if e.Model != "" && e.Model != "base_reward" && e.AmountMicroUSD > 0 && !e.CreatedAt.Before(since) && e.CreatedAt.Before(until) {
			if out[e.Model] > math.MaxInt64-e.AmountMicroUSD {
				return nil, fmt.Errorf("network model earnings overflow for %s", e.Model)
			}
			out[e.Model] += e.AmountMicroUSD
		}
	}
	return out, nil
}

func (s *PostgresStore) NetworkModelEarnings(ctx context.Context, since, until time.Time) (map[string]int64, error) {
	if err := validateInsightWindow(since, until); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT model, SUM(amount_micro_usd)
 FROM provider_earnings WHERE created_at >= $1 AND created_at < $2
 AND model <> '' AND model <> 'base_reward' AND amount_micro_usd > 0 GROUP BY model`, since, until)
	if err != nil {
		return nil, fmt.Errorf("network model earnings: %w", err)
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var id string
		var amount int64
		if err := rows.Scan(&id, &amount); err != nil {
			return nil, err
		}
		out[id] = amount
	}
	return out, rows.Err()
}
