// Pure, self-contained leaderboard formatting helpers.
//
// These are intentionally dependency-free so they can be unit tested in
// isolation. The richer USD/number formatters (`formatUSDFromMicro`,
// `formatNumber`) live in `stats/page.tsx` because `formatNumber` is shared
// across the whole stats page; we inject the USD formatter here rather than
// move that shared helper.

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
