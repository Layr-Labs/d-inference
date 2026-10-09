// Pure, dependency-free leaderboard formatting helpers, unit tested in
// isolation (see format.test.ts).

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

/**
 * Tailwind text-color token for a reward value. Rewards that are actually paid
 * out get the amber accent so they are visually differentiated from inference
 * work; zero rewards stay muted.
 */
export function rewardToneClass(rewardMicroUsd: number): string {
  return rewardMicroUsd > 0 ? "text-accent-amber" : "text-text-tertiary";
}
