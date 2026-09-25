package store

import (
	"context"
	"fmt"
)

// networkTotalsAllTime answers NetworkTotals for the all-time window from
// earnings_summary. The provider partition supplies work, base rewards, tokens
// and jobs: like the scan's work CTE it covers every earnings row with a
// provider key, whether or not an account was attached. The account partition
// is the provider-account set for ActiveAccounts and the ledger-reward join.
// The summary is complete whenever this runs: both backfills finish inside
// migrate(), before the process serves.
func (s *PostgresStore) networkTotalsAllTime(ctx context.Context) (NetworkTotalsRow, error) {
	q := `WITH providers AS (
	          SELECT COALESCE(SUM(total_micro_usd - total_base_reward_micro_usd),0) AS work_micro,
	                 COALESCE(SUM(total_base_reward_micro_usd),0)                   AS base_reward_micro,
	                 COALESCE(SUM(total_prompt_tokens + total_completion_tokens),0) AS tokens,
	                 COALESCE(SUM(total_count),0)                                   AS jobs
	          FROM earnings_summary WHERE key_type = 'provider' AND key <> ''
	      ),
	      accounts AS (
	          SELECT key AS account_id FROM earnings_summary WHERE key_type = 'account' AND key <> ''
	      ),
	      reward AS (
	          SELECT COALESCE(SUM(le.amount_micro_usd),0) AS reward_micro
	          FROM ledger_entries le
	          JOIN accounts a ON a.account_id = le.account_id
	          WHERE le.entry_type IN (` + rewardLedgerTypesSQLList() + `)
	      )
	      SELECT p.work_micro + p.base_reward_micro + r.reward_micro,
	             p.work_micro, p.base_reward_micro + r.reward_micro, p.tokens, p.jobs,
	             (SELECT COUNT(*) FROM accounts) AS active_accounts
	      FROM providers p, reward r`
	var t NetworkTotalsRow
	if err := s.pool.QueryRow(ctx, q).Scan(&t.EarningsMicroUSD, &t.WorkEarningsMicroUSD, &t.RewardEarningsMicroUSD, &t.Tokens, &t.Jobs, &t.ActiveAccounts); err != nil {
		return NetworkTotalsRow{}, fmt.Errorf("store: network totals (all-time): %w", err)
	}
	return t, nil
}

// leaderboardAllTime ranks the account partition of earnings_summary joined to
// the reward ledger, reproducing Leaderboard's all-time result without the
// provider_earnings scans. orderCol is one of the three fixed ranking columns.
// Errors surface as nil, matching Leaderboard.
func (s *PostgresStore) leaderboardAllTime(ctx context.Context, orderCol string, limit int) []LeaderboardRow {
	q := `WITH reward AS (
	          SELECT account_id, SUM(amount_micro_usd) AS reward_micro
	          FROM ledger_entries
	          WHERE account_id != '' AND entry_type IN (` + rewardLedgerTypesSQLList() + `)
	          GROUP BY account_id
	      )
	      SELECT s.key                                                    AS account_id,
	             s.total_micro_usd + COALESCE(r.reward_micro,0)            AS earnings_micro_usd,
	             s.total_micro_usd - s.total_base_reward_micro_usd          AS work_micro_usd,
	             s.total_base_reward_micro_usd + COALESCE(r.reward_micro,0) AS reward_micro_usd,
	             s.total_prompt_tokens + s.total_completion_tokens          AS tokens,
	             s.total_count                                              AS jobs
	      FROM earnings_summary s
	      LEFT JOIN reward r ON r.account_id = s.key
	      WHERE s.key_type = 'account' AND s.key <> ''
	      ORDER BY ` + orderCol + ` DESC, account_id ASC
	      LIMIT $1`
	rows, err := s.pool.Query(ctx, q, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := make([]LeaderboardRow, 0, limit)
	for rows.Next() {
		var r LeaderboardRow
		if err := rows.Scan(&r.AccountID, &r.EarningsMicroUSD, &r.WorkEarningsMicroUSD, &r.RewardEarningsMicroUSD, &r.Tokens, &r.Jobs); err != nil {
			return nil
		}
		out = append(out, r)
	}
	if rows.Err() != nil {
		return nil
	}
	return out
}
