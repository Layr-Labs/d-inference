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

// Wire types mirroring coordinator/api/public_provider_handlers.go:
// GET /v1/providers/{pseudonym} → /api/providers/profile/{pseudonym}

export interface PublicHardware {
  machine_model?: string;
  chip_name?: string;
  chip_family?: string;
  chip_tier?: string;
  memory_gb?: number;
  gpu_cores?: number;
}

export interface PublicReputation {
  score: number;
  total_jobs: number;
  successful_jobs: number;
  avg_response_time_ms?: number;
  challenges_passed: number;
}

export interface PublicProviderProfile {
  pseudonym: string;
  status: "online" | "serving" | "offline" | "untrusted" | string;
  trust_level: "hardware" | "self_signed" | "none" | string;
  hardware: PublicHardware;
  warm_models: string[];
  max_concurrency: number;
  reputation: PublicReputation;
  lifetime_tokens_generated: number;
}
