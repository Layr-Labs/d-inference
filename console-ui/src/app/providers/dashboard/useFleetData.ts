"use client";

// Fleet data hook: fetches BOTH /api/me/providers and /api/me/summary (the
// same-origin Next.js proxy routes, which forward to the coordinator with the
// caller's Privy token), polls every 15s, and keeps prior data visible across
// polls so the dashboard never flickers or blanks on a transient failure. The
// summary is best-effort — the page still renders if only the providers call
// succeeds.

import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import type { MyProvidersResponse, MySummaryResponse } from "../types";
import type { RoutingCtx } from "./routing";

const REFRESH_MS = 15_000;
const PROVIDERS_URL = "/api/me/providers";
const SUMMARY_URL = "/api/me/summary";

export interface FleetData {
  ready: boolean;
  authenticated: boolean;
  login: () => void;
  providersResp: MyProvidersResponse | null;
  summary: MySummaryResponse | null;
  ctx: RoutingCtx;
  /** True only during the very first load (before any data arrives). */
  loading: boolean;
  /** True whenever a fetch is in flight (drives the header spinner). */
  refreshing: boolean;
  /** Hard error — only set when there is no data to show. */
  error: string | null;
  /** A poll failed but we kept showing prior data. */
  pollFailed: boolean;
  /** ms timestamp of the last successful providers load. */
  lastUpdatedAt: number | null;
  refetch: () => void;
}

const DEFAULT_CTX_FROM = (resp: MyProvidersResponse | null): RoutingCtx => ({
  latest_provider_version: resp?.latest_provider_version ?? "",
  min_provider_version: resp?.min_provider_version ?? "",
  heartbeat_timeout_seconds: resp?.heartbeat_timeout_seconds ?? 90,
  challenge_max_age_seconds: resp?.challenge_max_age_seconds ?? 360,
});

export function useFleetData(): FleetData {
  const { ready, authenticated, login, getAccessToken } = useAuth();
  const [providersResp, setProvidersResp] = useState<MyProvidersResponse | null>(null);
  const [summary, setSummary] = useState<MySummaryResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pollFailed, setPollFailed] = useState(false);
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);

  // Track whether we currently have data without retriggering fetchAll.
  const hasDataRef = useRef(false);

  const fetchAll = useCallback(async () => {
    setRefreshing(true);
    try {
      const token = await getAccessToken().catch(() => null);
      if (!token) {
        if (!hasDataRef.current) setError("Not authenticated");
        else setPollFailed(true);
        return;
      }
      const headers = { Authorization: `Bearer ${token}` };

      // Providers is required; summary is best-effort.
      const [pRes, sRes] = await Promise.allSettled([
        fetch(PROVIDERS_URL, { headers, cache: "no-store" }),
        fetch(SUMMARY_URL, { headers, cache: "no-store" }),
      ]);

      if (pRes.status !== "fulfilled" || !pRes.value.ok) {
        const detail =
          pRes.status === "fulfilled" ? `HTTP ${pRes.value.status}` : pRes.reason?.message || "network error";
        throw new Error(detail);
      }

      const providers = (await pRes.value.json()) as MyProvidersResponse;
      setProvidersResp(providers);
      hasDataRef.current = true;
      setError(null);
      setPollFailed(false);
      setLastUpdatedAt(Date.now());

      if (sRes.status === "fulfilled" && sRes.value.ok) {
        try {
          setSummary((await sRes.value.json()) as MySummaryResponse);
        } catch {
          /* keep prior summary */
        }
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (!hasDataRef.current) setError(msg);
      else setPollFailed(true);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [getAccessToken]);

  useEffect(() => {
    if (!authenticated) {
      setLoading(false);
      return;
    }
    fetchAll();
    const id = setInterval(fetchAll, REFRESH_MS);
    return () => clearInterval(id);
  }, [authenticated, fetchAll]);

  return {
    ready,
    authenticated,
    login,
    providersResp,
    summary,
    ctx: DEFAULT_CTX_FROM(providersResp),
    loading,
    refreshing,
    error,
    pollFailed,
    lastUpdatedAt,
    refetch: fetchAll,
  };
}
