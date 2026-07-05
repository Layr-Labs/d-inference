"use client";

import { Award, Crown, Medal, type LucideIcon } from "lucide-react";
import type { LeaderboardEntry, LeaderboardMetric } from "./types";
import {
  formatAnnualizedUSD,
  formatDailyUSD,
  formatNumber,
  rewardToneClass,
} from "./format";

const EARNINGS_GRID = "grid grid-cols-[64px_minmax(0,1fr)_130px_130px_130px] gap-3";
const TOKENS_GRID = "grid grid-cols-[64px_minmax(0,1fr)_140px] gap-3";

// Gold / silver / bronze rank treatment, built from the app's accent tokens so
// it holds up in both light and dark themes. `row` is a subtle background tint
// that sets the top-3 rows apart from the rest of the table.
const MEDAL_STYLES: Record<number, { pill: string; row: string; icon: LucideIcon }> = {
  1: {
    pill: "border-accent-amber/40 bg-accent-amber/15 text-accent-amber",
    row: "bg-accent-amber/5",
    icon: Crown,
  },
  2: {
    pill: "border-border-subtle bg-bg-elevated text-text-secondary",
    row: "bg-bg-secondary/60",
    icon: Medal,
  },
  3: {
    pill: "border-accent-brand/30 bg-accent-brand/10 text-accent-brand",
    row: "bg-accent-brand/5",
    icon: Award,
  },
};

/** Subtle background tint for top-3 rows, empty string for everyone else. */
function rankRowTint(rank: number): string {
  return MEDAL_STYLES[rank]?.row ?? "";
}

/** Medal pill for ranks 1–3, plain "#N" for everyone else. */
function RankCell({ rank }: { rank: number }) {
  const medal = MEDAL_STYLES[rank];
  if (!medal) {
    return <span className="self-center font-mono font-semibold text-text-primary">#{rank}</span>;
  }
  const MedalIcon = medal.icon;
  return (
    <span
      className={`inline-flex items-center gap-1 self-center justify-self-start rounded-full border px-2 py-0.5 font-mono text-xs font-bold ${medal.pill}`}
    >
      <MedalIcon size={12} />
      {rank}
    </span>
  );
}

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
          className={`${EARNINGS_GRID} border-t border-border-dim px-4 py-3 text-sm ${rankRowTint(entry.rank)}`}
        >
          <RankCell rank={entry.rank} />
          <span className="self-center truncate font-mono text-text-secondary">{entry.pseudonym}</span>
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
          className={`${TOKENS_GRID} border-t border-border-dim px-4 py-3 text-sm ${rankRowTint(entry.rank)}`}
        >
          <RankCell rank={entry.rank} />
          <span className="self-center truncate font-mono text-text-secondary">{entry.pseudonym}</span>
          <span className="self-center text-right font-mono font-semibold text-text-primary">
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
