"use client";

import Link from "next/link";
import { Loader2, Trophy, Zap } from "lucide-react";
import { TopBar } from "@/components/TopBar";
import { useLeaderboard } from "./useLeaderboard";
import { MetricToggle } from "./Controls";
import { PodiumCard } from "./PodiumCard";
import { RankingsTable } from "./RankingsTable";

/**
 * Standalone /leaderboard page: a single ranking-focused card. Static 24h
 * ranking, earnings shown as annualized rates, tokens shown as 24h counts.
 */
export function LeaderboardContent() {
  const { metric, setMetric, leaderboard, loading, error } = useLeaderboard();

  const entries = leaderboard?.entries ?? [];
  const podium = entries.slice(0, 3);
  const updatedAt = leaderboard?.updated_at
    ? new Date(leaderboard.updated_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : "";

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Leaderboard" />
      <div className="flex-1 overflow-y-auto relative">
        <div className="max-w-4xl mx-auto px-3 sm:px-6 py-6 sm:py-8">
          <div className="rounded-xl border border-border-dim bg-bg-white p-5 shadow-sm">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <div className="flex items-center gap-2">
                  <Trophy size={16} className="text-accent-brand" />
                  <h2 className="text-sm font-semibold text-text-primary">Provider Leaderboard</h2>
                </div>
                <p className="mt-1 max-w-xl text-xs text-text-tertiary">
                  Pseudonymized provider accounts ranked by the last 24 hours.
                  {metric === "earnings"
                    ? " Earnings are shown as annualized rates extrapolated from the 24h window."
                    : " Ranked by tokens served in the 24h window."}
                  {updatedAt ? ` Updated ${updatedAt}.` : ""}
                </p>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <MetricToggle metric={metric} onChange={setMetric} />
                <Link
                  href="/providers/setup"
                  className="inline-flex items-center gap-1.5 rounded-lg bg-accent-brand px-3 py-1.5 text-sm font-semibold text-bg-primary shadow-sm transition-colors hover:bg-accent-brand/90"
                >
                  <Zap size={14} />
                  Earn Now
                </Link>
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
                No leaderboard activity in the last 24 hours yet.
              </div>
            ) : (
              <>
                <div className="mt-5 grid gap-3 md:grid-cols-3">
                  {podium.map((entry) => (
                    <PodiumCard key={entry.rank} entry={entry} metric={metric} />
                  ))}
                </div>
                <RankingsTable entries={entries} metric={metric} />
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
