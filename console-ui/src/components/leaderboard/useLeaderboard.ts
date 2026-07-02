"use client";

import { useEffect, useState } from "react";
import type {
  LeaderboardMetric,
  LeaderboardResponse,
  LeaderboardWindow,
  NetworkTotalsResponse,
} from "./types";

async function fetchLeaderboard(
  metric: LeaderboardMetric,
  window: LeaderboardWindow,
): Promise<LeaderboardResponse> {
  const params = new URLSearchParams({ metric, window, limit: "50" });
  const res = await fetch(`/api/leaderboard?${params.toString()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Leaderboard HTTP ${res.status}`);
  return res.json();
}

async function fetchNetworkTotals(window: LeaderboardWindow): Promise<NetworkTotalsResponse> {
  const params = new URLSearchParams({ window });
  const res = await fetch(`/api/network/totals?${params.toString()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Network totals HTTP ${res.status}`);
  return res.json();
}

export interface UseLeaderboardResult {
  metric: LeaderboardMetric;
  setMetric: (metric: LeaderboardMetric) => void;
  window: LeaderboardWindow;
  setWindow: (window: LeaderboardWindow) => void;
  leaderboard: LeaderboardResponse | null;
  totals: NetworkTotalsResponse | null;
  loading: boolean;
  error: string | null;
}

/**
 * Owns the metric/window selection and fetches the leaderboard + network
 * totals from the coordinator proxies whenever either changes.
 */
export function useLeaderboard(): UseLeaderboardResult {
  const [metric, setMetric] = useState<LeaderboardMetric>("earnings");
  const [window, setWindow] = useState<LeaderboardWindow>("7d");
  const [leaderboard, setLeaderboard] = useState<LeaderboardResponse | null>(null);
  const [totals, setTotals] = useState<NetworkTotalsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    async function loadLeaderboard() {
      try {
        const [nextLeaderboard, nextTotals] = await Promise.all([
          fetchLeaderboard(metric, window),
          fetchNetworkTotals(window),
        ]);
        if (cancelled) return;
        setLeaderboard(nextLeaderboard);
        setTotals(nextTotals);
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
  }, [metric, window]);

  return { metric, setMetric, window, setWindow, leaderboard, totals, loading, error };
}
