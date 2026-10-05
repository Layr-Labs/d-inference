package store

// LeaderboardMetric selects the ranking column for a leaderboard query.
type LeaderboardMetric string

const (
	LeaderboardEarnings LeaderboardMetric = "earnings"
	LeaderboardTokens   LeaderboardMetric = "tokens"
	LeaderboardJobs     LeaderboardMetric = "jobs"
)

// LeaderboardRow is a single account's aggregate across provider_earnings
// (inference work) combined with reward ledger entries (referral_reward and
// admin_reward). EarningsMicroUSD is the combined total of work + reward.
// Pseudonyms are computed at the API layer from AccountID, never returned
// from the store directly.
type LeaderboardRow struct {
	AccountID              string `json:"account_id"`
	EarningsMicroUSD       int64  `json:"earnings_micro_usd"`        // total = work + reward
	WorkEarningsMicroUSD   int64  `json:"work_earnings_micro_usd"`   // inference payouts
	RewardEarningsMicroUSD int64  `json:"reward_earnings_micro_usd"` // referral_reward + admin_reward
	Tokens                 int64  `json:"tokens"`
	Jobs                   int64  `json:"jobs"`
}

// NetworkTotalsRow holds aggregated network metrics for homepage stats.
type NetworkTotalsRow struct {
	EarningsMicroUSD       int64 `json:"earnings_micro_usd"` // total = work + reward
	WorkEarningsMicroUSD   int64 `json:"work_earnings_micro_usd"`
	RewardEarningsMicroUSD int64 `json:"reward_earnings_micro_usd"`
	Tokens                 int64 `json:"tokens"`
	Jobs                   int64 `json:"jobs"`
	ActiveAccounts         int64 `json:"active_accounts"`
}
