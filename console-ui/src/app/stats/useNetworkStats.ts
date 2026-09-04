"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
import { capacityModelsFromResponse, catalogDataFromResponse, type CapacityModelSummary, type CatalogDataSummary } from "@/lib/stats-model-filter";
import type { PlatformStats } from "./platform-types";
import type { NetworkWindowTotals } from "./types";

export const STATS_REFRESH_MS = 30_000;

type RequestLifecycle = {
  controller: AbortController;
  primaryFlight: boolean;
  secondaryFlight: boolean;
};

async function fetchJSON(url: string, signal: AbortSignal) {
  const response = await fetch(url, { signal, cache: "no-store" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

/** Keep the primary snapshot responsive even if a secondary endpoint is slow. */
export function useNetworkStats() {
  const [stats, setStats] = useState<PlatformStats | null>(null);
  const [catalogData, setCatalogData] = useState<CatalogDataSummary | null>(null);
  const [capacityModels, setCapacityModels] = useState<CapacityModelSummary[] | null>(null);
  const [totals24h, setTotals24h] = useState<NetworkWindowTotals | null>(null);
  const [snapshotAt, setSnapshotAt] = useState<string | null>(null);
  const [fetchedAt, setFetchedAt] = useState<string | null>(null);
  const [isMock, setIsMock] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [secondaryError, setSecondaryError] = useState(false);
  const requests = useRef<RequestLifecycle | null>(null);

  useEffect(() => {
    // Strict Mode replays this effect while requests from the first mount are
    // settling. Keep each mount's flight flags with its own abort controller.
    const lifecycle = { controller: new AbortController(), primaryFlight: false, secondaryFlight: false };
    requests.current = lifecycle;
    return () => lifecycle.controller.abort();
  }, []);

  const refresh = useCallback(() => {
    const flights = requests.current;
    if (!flights || flights.controller.signal.aborted) return;
    const lifecycle = flights.controller.signal;
    if (!flights.primaryFlight) {
      flights.primaryFlight = true;
      setRefreshing(true);
      // Allow the server's 20-second upstream deadline to return its error.
      const signal = AbortSignal.any([lifecycle, AbortSignal.timeout(25_000)]);
      const query = new URLSearchParams(window.location.search).get("mock") === "geo" ? "?mock=geo" : "";
      const loadPrimary = async () => {
        try {
          const response = await fetch(`/api/stats${query}`, { cache: "no-store", signal });
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const data = await response.json() as PlatformStats;
          if (!Array.isArray(data.providers) || !Array.isArray(data.models)) throw new Error("Invalid stats response");
          if (lifecycle.aborted) return;
          setStats(data);
          setIsMock(response.headers.get("X-Stats-Cache") === "MOCK");
          const capturedAt = response.headers.get("X-Stats-Snapshot-At");
          setSnapshotAt(capturedAt && Number.isFinite(Date.parse(capturedAt)) ? capturedAt : null);
          const fetched = response.headers.get("X-Stats-Fetched-At");
          setFetchedAt(fetched && Number.isFinite(Date.parse(fetched)) ? fetched : null);
          setError(null);
        } catch (cause: unknown) {
          if (!lifecycle.aborted) setError(cause instanceof Error && cause.name === "TimeoutError" ? "The network took too long to respond." : "The latest snapshot couldn’t be loaded.");
        } finally {
          flights.primaryFlight = false;
          if (!lifecycle.aborted) setRefreshing(false);
        }
      };
      void loadPrimary();
    }
    if (flights.secondaryFlight) return;
    flights.secondaryFlight = true;
    const signal = AbortSignal.any([lifecycle, AbortSignal.timeout(20_000)]);
    const loadSecondary = async () => {
      try {
        const [catalog, capacity, totals] = await Promise.allSettled([
          fetchJSON("/api/models", signal).then(catalogDataFromResponse),
          fetchJSON("/api/models/capacity", signal).then(capacityModelsFromResponse),
          fetchJSON("/api/network/totals?window=24h", signal),
        ]);
        if (lifecycle.aborted) return;
        // Failed auxiliary snapshots become unknown, not stale figures labelled current.
        setCatalogData(catalog.status === "fulfilled" ? catalog.value : null);
        setCapacityModels(capacity.status === "fulfilled" ? capacity.value : null);
        setTotals24h(totals.status === "fulfilled" && typeof totals.value?.tokens === "number" && typeof totals.value?.jobs === "number" ? totals.value : null);
        setSecondaryError(catalog.status === "rejected" || capacity.status === "rejected");
      } finally {
        flights.secondaryFlight = false;
      }
    };
    void loadSecondary();
  }, []);

  useVisiblePolling(refresh, STATS_REFRESH_MS);
  return { stats, catalogData, capacityModels, totals24h, snapshotAt, fetchedAt, isMock, refreshing, error, secondaryError, refresh };
}
