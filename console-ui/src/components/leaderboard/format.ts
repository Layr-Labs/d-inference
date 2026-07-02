// Pure, dependency-free leaderboard formatting helpers, unit tested in
// isolation (see format.test.ts).

import type { LeaderboardEntry, LeaderboardMetric } from "./types";

export function formatNumber(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return n.toLocaleString();
}

// Never abbreviated (no K/M) — full dollar amounts with thousands separators.
export function formatUSDFromMicro(value: number): string {
  const dollars = value / 1_000_000;
  if (dollars >= 10) return `$${Math.round(dollars).toLocaleString("en-US")}`;
  return `$${dollars.toFixed(2)}`;
}

/**
 * Annualized rate from a 24h earnings figure: micro-USD earned in the last
 * 24 hours extrapolated to a yearly rate. No "/yr" suffix — the surrounding
 * context (column header or card label) states the unit.
 */
export function formatAnnualizedUSD(micro24h: number): string {
  return formatUSDFromMicro(micro24h * 365);
}

/**
 * Per-day rate from a 24h earnings figure (the 24h amount IS the daily rate).
 * Carries its own "/day" suffix because it appears as secondary text under
 * annualized values, outside the header's "/ yr" context.
 */
export function formatDailyUSD(micro24h: number): string {
  return `${formatUSDFromMicro(micro24h)}/day`;
}

/** Big headline value for a ranked entry: annualized earnings or 24h tokens. */
export function formatLeaderboardValue(
  entry: LeaderboardEntry,
  metric: LeaderboardMetric,
): string {
  if (metric === "earnings") return formatAnnualizedUSD(entry.earnings_micro_usd);
  return formatNumber(entry.tokens);
}

/**
 * Builds the "Work $X/yr · Rewards $Y/yr" breakdown sub-line under combined
 * earnings figures. The work/reward split is the whole point of the
 * leaderboard rewards feature, so this pins the label order and which
 * micro-USD value maps to which label.
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
