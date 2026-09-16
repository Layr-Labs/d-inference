package postgres

import (
	"context"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// rewardLedgerTypesSQLList renders RewardLedgerTypes as a comma-separated list
// of single-quoted SQL string literals (e.g. "'referral_reward','admin_reward'")
// for use in an IN (...) clause. The values are package constants, never user
// input, so literal interpolation here is safe from SQL injection.
func rewardLedgerTypesSQLList() string {
	out := ""
	for i, t := range contracts.RewardLedgerTypes {
		if i > 0 {
			out += ","
		}
		out += "'" + string(t) + "'"
	}
	return out
}

// Leaderboard returns the top N accounts ranked by the given metric over the
// given time window. Base-reward rows live in provider_earnings for
// provider-facing history, but count as reward earnings here so they do not
// inflate inference work/jobs/tokens. Ledger reward-only accounts (e.g.
// consumer-only referrers) never appear on the provider leaderboard.
func (s *Store) Leaderboard(metric contracts.LeaderboardMetric, since time.Time, limit int) []contracts.LeaderboardRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if limit <= 0 || limit > 200 {
		limit = 50
	}

	orderCol := "earnings_micro_usd"
	switch metric {
	case contracts.LeaderboardTokens:
		orderCol = "tokens"
	case contracts.LeaderboardJobs:
		orderCol = "jobs"
	}

	// `since` is bound once as $1 and referenced in both CTEs; `limit` is the
	// final positional arg. account_id != '' filters out unassigned earnings.
	args := []any{}
	workWhere := ` WHERE account_id != '' AND model <> 'base_reward'`
	baseRewardWhere := ` WHERE account_id != '' AND model = 'base_reward'`
	rewardSince := ""
	if !since.IsZero() {
		args = append(args, since)
		workWhere += ` AND created_at >= $1`
		baseRewardWhere += ` AND created_at >= $1`
		rewardSince = ` AND created_at >= $1`
	}

	q := `WITH work AS (
	          SELECT account_id,
		                 SUM(amount_micro_usd)                  AS work_micro,
		                 SUM(prompt_tokens + completion_tokens) AS tokens,
		                 COUNT(*)                               AS jobs
		          FROM provider_earnings` + workWhere + `
		          GROUP BY account_id
		      ),
		      base_reward AS (
	          SELECT account_id,
	                 SUM(amount_micro_usd) AS reward_micro
	          FROM provider_earnings` + baseRewardWhere + `
	          GROUP BY account_id
	      ),
	      reward AS (
	          SELECT account_id,
	                 SUM(amount_micro_usd) AS reward_micro
	          FROM ledger_entries
	          WHERE account_id != '' AND entry_type IN (` + rewardLedgerTypesSQLList() + `)` + rewardSince + `
	          GROUP BY account_id
	      )
	      SELECT COALESCE(w.account_id, br.account_id)  AS account_id,
	             COALESCE(w.work_micro,0) + COALESCE(br.reward_micro,0) + COALESCE(r.reward_micro,0) AS earnings_micro_usd,
	             COALESCE(w.work_micro,0)                AS work_micro_usd,
	             COALESCE(br.reward_micro,0) + COALESCE(r.reward_micro,0) AS reward_micro_usd,
	             COALESCE(w.tokens,0)                    AS tokens,
	             COALESCE(w.jobs,0)                      AS jobs
	      FROM work w
	      FULL OUTER JOIN base_reward br ON br.account_id = w.account_id
	      LEFT JOIN reward r ON r.account_id = COALESCE(w.account_id, br.account_id)
	      WHERE COALESCE(w.account_id, br.account_id) IS NOT NULL
	      ORDER BY ` + orderCol + ` DESC, account_id ASC
	      LIMIT $` + strconv.Itoa(len(args)+1)
	args = append(args, limit)

	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()

	out := make([]contracts.LeaderboardRow, 0, limit)
	for rows.Next() {
		var r contracts.LeaderboardRow
		if err := rows.Scan(&r.AccountID, &r.EarningsMicroUSD, &r.WorkEarningsMicroUSD, &r.RewardEarningsMicroUSD, &r.Tokens, &r.Jobs); err != nil {
			continue
		}
		out = append(out, r)
	}
	return out
}
