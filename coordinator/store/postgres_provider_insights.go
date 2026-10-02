package store

import (
	"context"
	"fmt"
	"time"
)

// The account/time predicate uses idx_provider_earnings_account. Aggregate in
// SQL rather than fetching/truncating a page of earnings. UTC bins are stable
// regardless of the database session timezone. Bound both runtime and output.
func (s *PostgresStore) ProviderInsightGroups(ctx context.Context, account string, since, until time.Time) ([]ProviderInsightGroup, error) {
	if err := validateInsightWindow(since, until); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT
		to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD') AS day,
		model, provider_id,
		COALESCE(sum(amount_micro_usd) FILTER (WHERE model <> 'base_reward'), 0),
		COALESCE(sum(amount_micro_usd) FILTER (WHERE model = 'base_reward'), 0),
		count(*) FILTER (WHERE model <> 'base_reward'),
		COALESCE(sum(prompt_tokens) FILTER (WHERE model <> 'base_reward'), 0),
		COALESCE(sum(completion_tokens) FILTER (WHERE model <> 'base_reward'), 0)
		FROM provider_earnings
		WHERE account_id = $1 AND created_at >= $2 AND created_at < $3
		GROUP BY day, model, provider_id ORDER BY day, model, provider_id LIMIT $4`,
		account, since, until, providerInsightGroupLimit+1)
	if err != nil {
		return nil, fmt.Errorf("provider insights: %w", err)
	}
	defer rows.Close()
	out := make([]ProviderInsightGroup, 0)
	for rows.Next() {
		var g ProviderInsightGroup
		if err := rows.Scan(&g.Day, &g.Model, &g.ProviderID, &g.WorkMicroUSD, &g.BaseRewardMicroUSD, &g.Jobs, &g.PromptTokens, &g.CompletionTokens); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) > providerInsightGroupLimit {
		return nil, fmt.Errorf("provider insights: too many groups")
	}
	return out, nil
}
