"use client";

import type { LeaderboardEntry, LeaderboardMetric } from "./types";
import {
  formatAnnualizedUSD,
  formatDailyUSD,
  formatNumber,
  rewardToneClass,
} from "./format";

const EARNINGS_GRID = "grid grid-cols-[56px_minmax(0,1fr)_130px_130px_130px] gap-3";
const TOKENS_GRID = "grid grid-cols-[56px_minmax(0,1fr)_140px] gap-3";

/** Annualized value with the per-day rate as quieter secondary text below. */
function EarningsCell({
  micro24h,
  toneClass = "text-text-secondary",
}: {
  micro24h: number;
  toneClass?: string;
}) {
  return (
    <span className="text-right">
      <span className={`block font-mono ${toneClass}`}>{formatAnnualizedUSD(micro24h)}</span>
      <span className="block text-[10px] font-mono text-text-tertiary">
        {formatDailyUSD(micro24h)}
      </span>
    </span>
  );
}

function EarningsRows({ entries }: { entries: LeaderboardEntry[] }) {
  return (
    <>
      <div
        className={`${EARNINGS_GRID} bg-bg-secondary px-4 py-2.5 text-[10px] font-mono uppercase tracking-wider text-text-tertiary`}
      >
        <span>Rank</span>
        <span>Provider</span>
        <span className="text-right">Earnings / yr</span>
        <span className="text-right">Work / yr</span>
        <span className="text-right">Rewards / yr</span>
      </div>
      {entries.map((entry) => (
        <div
          key={`${entry.rank}-${entry.pseudonym}`}
          className={`${EARNINGS_GRID} border-t border-border-dim px-4 py-3 text-sm`}
        >
          <span className="font-mono font-semibold text-text-primary">#{entry.rank}</span>
          <span className="truncate font-mono text-text-secondary">{entry.pseudonym}</span>
          <EarningsCell
            micro24h={entry.earnings_micro_usd}
            toneClass="font-semibold text-text-primary"
          />
          <EarningsCell micro24h={entry.work_earnings_micro_usd} />
          <EarningsCell
            micro24h={entry.reward_earnings_micro_usd}
            toneClass={rewardToneClass(entry.reward_earnings_micro_usd)}
          />
        </div>
      ))}
    </>
  );
}

function TokensRows({ entries }: { entries: LeaderboardEntry[] }) {
  return (
    <>
      <div
        className={`${TOKENS_GRID} bg-bg-secondary px-4 py-2.5 text-[10px] font-mono uppercase tracking-wider text-text-tertiary`}
      >
        <span>Rank</span>
        <span>Provider</span>
        <span className="text-right">Tokens · 24h</span>
      </div>
      {entries.map((entry) => (
        <div
          key={`${entry.rank}-${entry.pseudonym}`}
          className={`${TOKENS_GRID} border-t border-border-dim px-4 py-3 text-sm`}
        >
          <span className="font-mono font-semibold text-text-primary">#{entry.rank}</span>
          <span className="truncate font-mono text-text-secondary">{entry.pseudonym}</span>
          <span className="text-right font-mono font-semibold text-text-primary">
            {formatNumber(entry.tokens)}
          </span>
        </div>
      ))}
    </>
  );
}

/**
 * Rankings table. Earnings mode: annualized total/work/rewards, no token
 * counts. Tokens mode: 24h tokens served, no earnings.
 */
export function RankingsTable({
  entries,
  metric,
}: {
  entries: LeaderboardEntry[];
  metric: LeaderboardMetric;
}) {
  return (
    <div className="mt-5 overflow-x-auto rounded-xl border border-border-dim">
      <div className={metric === "earnings" ? "min-w-[640px]" : "min-w-[420px]"}>
        {metric === "earnings" ? (
          <EarningsRows entries={entries} />
        ) : (
          <TokensRows entries={entries} />
        )}
      </div>
    </div>
  );
}
