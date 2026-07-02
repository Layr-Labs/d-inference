"use client";

import { useEffect, useState } from "react";
import { LEADERBOARD_WINDOW } from "./types";
import type { LeaderboardMetric, LeaderboardResponse } from "./types";

async function fetchLeaderboard(metric: LeaderboardMetric): Promise<LeaderboardResponse> {
  const params = new URLSearchParams({ metric, window: LEADERBOARD_WINDOW, limit: "50" });
  const res = await fetch(`/api/leaderboard?${params.toString()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Leaderboard HTTP ${res.status}`);
  return res.json();
}

export interface UseLeaderboardResult {
  metric: LeaderboardMetric;
  setMetric: (metric: LeaderboardMetric) => void;
  leaderboard: LeaderboardResponse | null;
  loading: boolean;
  error: string | null;
}

/**
 * Owns the earnings/tokens metric selection and fetches the 24h ranking from
 * the coordinator proxy whenever it changes.
 */
export function useLeaderboard(): UseLeaderboardResult {
  const [metric, setMetric] = useState<LeaderboardMetric>("earnings");
  const [leaderboard, setLeaderboard] = useState<LeaderboardResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    async function loadLeaderboard() {
      try {
        const next = await fetchLeaderboard(metric);
        if (cancelled) return;
        setLeaderboard(next);
      } catch (err: unknown) {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load leaderboard");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    void loadLeaderboard();

    return () => {
      cancelled = true;
    };
  }, [metric]);

  return { metric, setMetric, leaderboard, loading, error };
}
