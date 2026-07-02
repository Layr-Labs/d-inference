// Pure, dependency-free leaderboard formatting helpers, unit tested in
// isolation (see format.test.ts).

import type { LeaderboardEntry, LeaderboardMetric } from "./types";

export function formatNumber(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return n.toLocaleString();
}

export function formatUSDFromMicro(value: number): string {
  const dollars = value / 1_000_000;
  if (dollars >= 1000) return `$${formatNumber(Math.round(dollars))}`;
  if (dollars >= 10) return `$${dollars.toFixed(0)}`;
  return `$${dollars.toFixed(2)}`;
}

export function formatLeaderboardValue(
  entry: LeaderboardEntry,
  metric: LeaderboardMetric,
): string {
  if (metric === "earnings") return formatUSDFromMicro(entry.earnings_micro_usd);
  if (metric === "tokens") return formatNumber(entry.tokens);
  return formatNumber(entry.jobs);
}

/**
 * Builds the "Work $X · Rewards $Y" breakdown sub-line used under combined
 * earnings figures (totals strip + podium cards). The work/reward split is the
 * whole point of the leaderboard rewards feature, so this pins the label order
 * and which micro-USD value maps to which label.
 */
export function formatEarningsBreakdown(
  workMicroUsd: number,
  rewardMicroUsd: number,
  formatUSD: (micro: number) => string,
): string {
  return `Work ${formatUSD(workMicroUsd)} · Rewards ${formatUSD(rewardMicroUsd)}`;
}

/**
 * Tailwind text-color token for a reward value. Rewards that are actually paid
 * out get the amber accent so they are visually differentiated from inference
 * work; zero rewards stay muted.
 */
export function rewardToneClass(rewardMicroUsd: number): string {
  return rewardMicroUsd > 0 ? "text-accent-amber" : "text-text-tertiary";
}

/** Rank badge tone for the top-3 podium cards. */
export function leaderboardRankTone(rank: number): string {
  if (rank === 1) return "border-accent-brand/35 bg-accent-brand/10 text-accent-brand";
  if (rank === 2) return "border-accent-green/30 bg-accent-green/10 text-accent-green";
  return "border-accent-amber/30 bg-accent-amber-dim text-accent-amber";
}
