"use client";

import type { LeaderboardEntry, LeaderboardMetric } from "./types";
import {
  formatEarningsBreakdown,
  formatLeaderboardValue,
  formatNumber,
  formatUSDFromMicro,
  leaderboardRankTone,
} from "./format";

/** Top-3 podium card: pseudonym, earnings/tokens sub-lines, big metric value. */
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
        <div className="min-w-0">
          <p className="truncate font-mono text-sm font-semibold text-text-primary">
            {entry.pseudonym}
          </p>
          <p className="mt-1 text-xs font-mono text-text-tertiary">
            {formatUSDFromMicro(entry.earnings_micro_usd)} / {formatNumber(entry.tokens)} tokens
          </p>
          <p className="mt-0.5 text-[10px] font-mono text-text-tertiary">
            {formatEarningsBreakdown(
              entry.work_earnings_micro_usd,
              entry.reward_earnings_micro_usd,
              formatUSDFromMicro,
            )}
          </p>
        </div>
        <span className={`rounded-lg border px-2 py-1 text-xs font-mono font-bold ${rankTone}`}>
          #{entry.rank}
        </span>
      </div>
      <p className="mt-4 text-2xl font-mono font-bold text-text-primary">
        {formatLeaderboardValue(entry, metric)}
      </p>
      <p className="mt-1 text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
        Ranked by {metric}
      </p>
    </div>
  );
}
