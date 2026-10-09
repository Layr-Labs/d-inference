"use client";

import { useEffect, useRef, useState } from "react";
import type { NetworkSeriesResponse, TrafficRange } from "../types";

/** Every range uses the history endpoint's explicit completed-bucket boundary. */
export function useTrafficSeries(range: TrafficRange, refreshToken: string | null) {
  const [history, setHistory] = useState<NetworkSeriesResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [revision, setRevision] = useState(0);
  const cache = useRef(new Map<TrafficRange, { data: NetworkSeriesResponse; fetchedAt: number }>());

  useEffect(() => {
    const previous = cache.current.get(range);
    setError(false);
    if (previous && Date.now() - previous.fetchedAt < 30_000) {
      setHistory(previous.data);
      setLoading(false);
      return;
    }
    const controller = new AbortController();
    setLoading(true);
    async function load() {
      try {
        const response = await fetch(`/api/network/series?window=${range}`, { cache: "no-store", signal: AbortSignal.any([controller.signal, AbortSignal.timeout(20_000)]) });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const value = await response.json() as NetworkSeriesResponse;
        if (!Array.isArray(value.time_series) || value.window !== range || !Number.isFinite(Date.parse(value.end_at))) throw new Error("Invalid series boundary");
        if (controller.signal.aborted) return;
        cache.current.set(range, { data: value, fetchedAt: Date.now() });
        setHistory(value);
      } catch {
        if (!controller.signal.aborted) setError(true);
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }
    load();
    return () => controller.abort();
  }, [range, refreshToken, revision]);

  return { response: history?.window === range ? history : null, loading, error, retry: () => setRevision((value) => value + 1) };
}
