"use client";

import type { LeaderboardEntry } from "./types";
import { formatNumber, formatUSDFromMicro, rewardToneClass } from "./format";

const GRID = "grid grid-cols-[56px_minmax(0,1fr)_110px_110px_110px_96px_72px] gap-3";

/** Full rankings table: rank, pseudonym, earnings/work/rewards, tokens, jobs. */
export function RankingsTable({ entries }: { entries: LeaderboardEntry[] }) {
  return (
    <div className="mt-5 overflow-x-auto rounded-xl border border-border-dim">
      <div className="min-w-[760px]">
        <div
          className={`${GRID} bg-bg-secondary px-4 py-2.5 text-[10px] font-mono uppercase tracking-wider text-text-tertiary`}
        >
          <span>Rank</span>
          <span>Provider</span>
          <span className="text-right">Earnings</span>
          <span className="text-right">Work</span>
          <span className="text-right">Rewards</span>
          <span className="text-right">Tokens</span>
          <span className="text-right">Jobs</span>
        </div>
        {entries.map((entry) => (
          <div
            key={`${entry.rank}-${entry.pseudonym}`}
            className={`${GRID} border-t border-border-dim px-4 py-3 text-sm`}
          >
            <span className="font-mono font-semibold text-text-primary">#{entry.rank}</span>
            <span className="truncate font-mono text-text-secondary">{entry.pseudonym}</span>
            <span className="text-right font-mono font-semibold text-text-primary">
              {formatUSDFromMicro(entry.earnings_micro_usd)}
            </span>
            <span className="text-right font-mono text-text-secondary">
              {formatUSDFromMicro(entry.work_earnings_micro_usd)}
            </span>
            <span
              className={`text-right font-mono ${rewardToneClass(entry.reward_earnings_micro_usd)}`}
            >
              {formatUSDFromMicro(entry.reward_earnings_micro_usd)}
            </span>
            <span className="text-right font-mono text-text-secondary">
              {formatNumber(entry.tokens)}
            </span>
            <span className="text-right font-mono text-text-secondary">
              {formatNumber(entry.jobs)}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
