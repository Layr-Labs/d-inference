"use client";

import type { LeaderboardEntry, LeaderboardMetric } from "./types";
import {
  formatAnnualizedUSD,
  formatEarningsBreakdown,
  formatLeaderboardValue,
  leaderboardRankTone,
} from "./format";

/**
 * Top-3 podium card. Earnings mode shows the annualized total with the
 * work/rewards split (no token counts); tokens mode shows 24h tokens only
 * (no earnings).
 */
export function PodiumCard({
  entry,
  metric,
}: {
  entry: LeaderboardEntry;
  metric: LeaderboardMetric;
}) {
  const rankTone = leaderboardRankTone(entry.rank);

  return (
    <div className="rounded-xl border border-border-dim bg-bg-secondary p-4">
      <div className="flex items-start justify-between gap-3">
        <p className="min-w-0 truncate font-mono text-sm font-semibold text-text-primary">
          {entry.pseudonym}
        </p>
        <span className={`rounded-lg border px-2 py-1 text-xs font-mono font-bold ${rankTone}`}>
          #{entry.rank}
        </span>
      </div>
      <p className="mt-4 text-2xl font-mono font-bold text-text-primary">
        {formatLeaderboardValue(entry, metric)}
      </p>
      <p className="mt-1 text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
        {metric === "earnings" ? "Annualized rate · last 24h" : "Tokens served · last 24h"}
      </p>
      {metric === "earnings" && (
        <p className="mt-2 text-[11px] font-mono text-text-tertiary">
          {formatEarningsBreakdown(
            entry.work_earnings_micro_usd,
            entry.reward_earnings_micro_usd,
            formatAnnualizedUSD,
          )}
        </p>
      )}
    </div>
  );
}
