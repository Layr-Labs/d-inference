"use client";

import Link from "next/link";
import { Loader2, Trophy, Zap } from "lucide-react";
import { TopBar } from "@/components/TopBar";
import { useLeaderboard } from "./useLeaderboard";
import { MetricToggle, WindowToggle } from "./Controls";
import { TotalsStrip } from "./TotalsStrip";
import { PodiumCard } from "./PodiumCard";
import { RankingsTable } from "./RankingsTable";

/**
 * Thin orchestrator for the standalone /leaderboard page: header card with
 * window controls + network totals, then the rankings card (metric controls,
 * podium, table).
 */
export function LeaderboardContent() {
  const {
    metric,
    setMetric,
    window,
    setWindow,
    leaderboard,
    totals,
    loading,
    error,
  } = useLeaderboard();

  const entries = leaderboard?.entries ?? [];
  const podium = entries.slice(0, 3);
  const updatedAt = leaderboard?.updated_at
    ? new Date(leaderboard.updated_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : "";

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Leaderboard" />
      <div className="flex-1 overflow-y-auto relative">
        <div className="max-w-5xl mx-auto px-3 sm:px-6 py-6 sm:py-8 space-y-5">
          <div className="rounded-xl border border-border-dim bg-bg-white p-5 shadow-sm">
            <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
              <div>
                <div className="flex items-center gap-2">
                  <Trophy size={16} className="text-accent-brand" />
                  <h2 className="text-sm font-semibold text-text-primary">Provider Earnings Leaderboard</h2>
                </div>
                <p className="mt-1 max-w-2xl text-xs text-text-tertiary">
                  Pseudonymized provider accounts ranked from the coordinator leaderboard. Earnings
                  combine <span className="text-text-secondary">inference work</span> (serving requests)
                  and <span className="text-accent-amber">network rewards</span> (incentives the network
                  pays providers for participation). Each window is a{" "}
                  <span className="text-text-secondary">rolling lookback</span> ending now
                  (e.g. 24h = the last 24 hours), not a fixed calendar day.
                </p>
                <p className="mt-2 max-w-2xl rounded-lg border border-border-dim bg-bg-secondary px-3 py-2 text-xs text-text-tertiary">
                  These are <span className="text-text-secondary">actual earnings during early network ramp-up</span>,
                  not steady-state figures. Request acceptance is intentionally conservative today and is being
                  scaled up as we validate the data, so live numbers run well below the{" "}
                  <Link href="/earn" className="text-accent-brand hover:underline">
                    earnings calculator
                  </Link>{" "}
                  projection, which estimates potential at full utilization.
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <Link
                  href="/providers/setup"
                  className="inline-flex items-center gap-1.5 rounded-lg bg-accent-brand px-3 py-1.5 text-sm font-semibold text-bg-primary shadow-sm transition-colors hover:bg-accent-brand/90"
                >
                  <Zap size={14} />
                  Earn Now
                </Link>
                <WindowToggle window={window} onChange={setWindow} />
              </div>
            </div>

            <TotalsStrip totals={totals} />
          </div>

          <div className="rounded-xl border border-border-dim bg-bg-white p-5 shadow-sm">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h3 className="text-sm font-semibold text-text-primary">Rankings</h3>
                <p className="mt-1 text-xs text-text-tertiary">
                  {updatedAt ? `Updated ${updatedAt}` : "Fresh values load from the coordinator"}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <MetricToggle metric={metric} onChange={setMetric} />
              </div>
            </div>

            {loading ? (
              <div className="mt-8 flex items-center justify-center py-12 text-text-tertiary">
                <Loader2 size={22} className="animate-spin" />
              </div>
            ) : error ? (
              <div className="mt-5 rounded-xl border border-accent-red/20 bg-accent-red/5 p-5 text-sm text-accent-red">
                {error}
              </div>
            ) : entries.length === 0 ? (
              <div className="mt-5 rounded-xl border border-dashed border-border-dim bg-bg-secondary p-8 text-center text-sm text-text-tertiary">
                No leaderboard activity for this window yet.
              </div>
            ) : (
              <>
                <div className="mt-5 grid gap-3 md:grid-cols-3">
                  {podium.map((entry) => (
                    <PodiumCard key={entry.rank} entry={entry} metric={metric} />
                  ))}
                </div>
                <RankingsTable entries={entries} />
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
