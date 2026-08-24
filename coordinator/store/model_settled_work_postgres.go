package store

import (
	"context"
	"fmt"
	"time"
)

// ModelSettledWorkTotals aggregates positive inference settlements in
// [since, until). This intentionally uses the existing provider_earnings table
// without adding a startup-time migration or blocking index build.
func (s *PostgresStore) ModelSettledWorkTotals(since, until time.Time) ([]ModelSettledWorkTotal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, `
		SELECT model,
		       COALESCE(SUM(amount_micro_usd), 0),
		       COALESCE(SUM(prompt_tokens), 0),
		       COALESCE(SUM(completion_tokens), 0),
		       COUNT(*)
		FROM provider_earnings
		WHERE created_at >= $1
		  AND created_at < $2
		  AND model <> ''
		  AND model <> 'base_reward'
		  AND amount_micro_usd > 0
		GROUP BY model
		ORDER BY model`,
		since, until,
	)
	if err != nil {
		return nil, fmt.Errorf("store: aggregate settled model work: %w", err)
	}
	defer rows.Close()

	out := make([]ModelSettledWorkTotal, 0)
	for rows.Next() {
		var total ModelSettledWorkTotal
		if err := rows.Scan(
			&total.Model,
			&total.WorkPayoutMicroUSD,
			&total.PromptTokens,
			&total.CompletionTokens,
			&total.Jobs,
		); err != nil {
			return nil, fmt.Errorf("store: scan settled model work: %w", err)
		}
		out = append(out, total)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: read settled model work: %w", err)
	}
	return out, nil
}
