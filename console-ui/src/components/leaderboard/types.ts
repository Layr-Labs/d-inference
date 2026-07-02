// Wire types mirroring the coordinator leaderboard endpoints
// (`coordinator/api/leaderboard.go`): /v1/leaderboard and /v1/network/totals,
// proxied through /api/leaderboard and /api/network/totals.

export type LeaderboardMetric = "earnings" | "tokens" | "jobs";
export type LeaderboardWindow = "24h" | "7d" | "30d" | "all";

export interface LeaderboardEntry {
  rank: number;
  pseudonym: string;
  earnings_micro_usd: number; // TOTAL = work + reward
  work_earnings_micro_usd: number; // inference work
  reward_earnings_micro_usd: number; // non-inference network rewards
  tokens: number;
  jobs: number;
}

export interface LeaderboardResponse {
  metric: LeaderboardMetric;
  window: LeaderboardWindow;
  entries: LeaderboardEntry[];
  updated_at: string;
}

export interface NetworkTotalsResponse {
  window: LeaderboardWindow;
  earnings_micro_usd: number; // TOTAL = work + reward
  work_earnings_micro_usd: number; // inference work
  reward_earnings_micro_usd: number; // non-inference network rewards
  tokens: number;
  jobs: number;
  active_accounts: number;
  updated_at: string;
}
