"use client";

import { Award, Crown, Medal, type LucideIcon } from "lucide-react";
import type { LeaderboardEntry, LeaderboardMetric } from "./types";
import {
  formatAnnualizedUSD,
  formatEarningsBreakdown,
  formatLeaderboardValue,
} from "./format";

interface PodiumStyle {
  container: string;
  medal: string;
  rankPill: string;
  icon: LucideIcon;
}

// Gold / silver / bronze treatment built from the app's accent tokens so it
// holds up in both light and dark themes.
const PODIUM_STYLES: Record<number, PodiumStyle> = {
  1: {
    container: "border-accent-amber/40 bg-accent-amber-dim",
    medal: "border-accent-amber/40 bg-accent-amber/15 text-accent-amber",
    rankPill: "border-accent-amber/40 bg-accent-amber/15 text-accent-amber",
    icon: Crown,
  },
  2: {
    container: "border-border-subtle bg-bg-secondary",
    medal: "border-border-subtle bg-bg-elevated text-text-secondary",
    rankPill: "border-border-subtle bg-bg-elevated text-text-secondary",
    icon: Medal,
  },
  3: {
    container: "border-accent-brand/25 bg-accent-brand/5",
    medal: "border-accent-brand/30 bg-accent-brand/10 text-accent-brand",
    rankPill: "border-accent-brand/30 bg-accent-brand/10 text-accent-brand",
    icon: Award,
  },
};

/**
 * Top-3 podium card with medal styling. Earnings mode shows the annualized
 * total with the work/rewards split (no token counts); tokens mode shows 24h
 * tokens only (no earnings).
 */
export function PodiumCard({
  entry,
  metric,
}: {
  entry: LeaderboardEntry;
  metric: LeaderboardMetric;
}) {
  const style = PODIUM_STYLES[entry.rank] ?? PODIUM_STYLES[3];
  const MedalIcon = style.icon;

  return (
    <div className={`rounded-xl border p-5 shadow-sm ${style.container}`}>
      <div className="flex items-center justify-between gap-3">
        <span
          className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full border ${style.medal}`}
        >
          <MedalIcon size={16} />
        </span>
        <span
          className={`rounded-full border px-2.5 py-1 text-xs font-mono font-bold ${style.rankPill}`}
        >
          #{entry.rank}
        </span>
      </div>
      <p className="mt-4 truncate font-mono text-sm font-semibold text-text-primary">
        {entry.pseudonym}
      </p>
      <p className="mt-1.5 text-3xl font-mono font-bold tracking-tight text-text-primary">
        {formatLeaderboardValue(entry, metric)}
      </p>
      <p className="mt-1 text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
        {metric === "earnings" ? "Annualized rate · last 24h" : "Tokens served · last 24h"}
      </p>
      {metric === "earnings" && (
        <p className="mt-3 border-t border-border-dim pt-2.5 text-[11px] font-mono text-text-tertiary">
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
