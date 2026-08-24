package store

import (
	"context"
	"fmt"
	"time"
)

// ModelSettledWorkTotals aggregates positive inference settlements by the
// consumer-requested public model in [since, until). Legacy settlement rows use
// the matching usage record only when its non-empty public identity is
// unambiguous; anything else stays in the empty audit group.
func (s *PostgresStore) ModelSettledWorkTotals(since, until time.Time) ([]ModelSettledWorkTotal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, `
		WITH settled AS (
			SELECT COALESCE(
				       NULLIF(earnings.public_model, ''),
				       NULLIF(usage_model.public_model, ''),
				       ''
			       ) AS public_model,
			       earnings.amount_micro_usd,
			       earnings.prompt_tokens,
			       earnings.completion_tokens
			FROM provider_earnings AS earnings
			LEFT JOIN LATERAL (
				SELECT CASE
					       WHEN MIN(usage.public_model) = MAX(usage.public_model)
					       THEN MIN(usage.public_model)
					       ELSE ''
				       END AS public_model
				FROM usage
				WHERE usage.request_id = earnings.job_id
				  AND usage.public_model <> ''
			) AS usage_model
			  ON earnings.public_model = ''
			 AND earnings.job_id <> ''
			WHERE earnings.created_at >= $1
			  AND earnings.created_at < $2
			  AND earnings.model <> ''
			  AND earnings.model <> 'base_reward'
			  AND earnings.amount_micro_usd > 0
		)
		SELECT public_model,
		       COALESCE(SUM(amount_micro_usd), 0),
		       COALESCE(SUM(prompt_tokens), 0),
		       COALESCE(SUM(completion_tokens), 0),
		       COUNT(*)
		FROM settled
		GROUP BY public_model
		ORDER BY public_model`,
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
			&total.PublicModel,
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
