// Wire types mirroring the coordinator leaderboard endpoint
// (`coordinator/api/leaderboard.go`): /v1/leaderboard, proxied through
// /api/leaderboard.

/** UI ranks by earnings or tokens only (the wire also supports "jobs"). */
export type LeaderboardMetric = "earnings" | "tokens";

/** The ranking is always computed from the last 24 hours. */
export const LEADERBOARD_WINDOW = "24h";

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
  metric: string;
  window: string;
  entries: LeaderboardEntry[];
  updated_at: string;
}
