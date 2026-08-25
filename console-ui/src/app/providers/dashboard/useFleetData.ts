"use client";

// Fleet data hook: fetches BOTH /api/me/providers and /api/me/summary (the
// same-origin Next.js proxy routes, which forward to the coordinator with the
// caller's Privy token), polls every 15s, and keeps prior data visible across
// polls so the dashboard never flickers or blanks on a transient failure. The
// summary is best-effort — the page still renders if only the providers call
// succeeds.

import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
import type {
  HardwareAdmissionAttempt,
  HardwareAdmissionAttemptsResponse,
  MyProvidersResponse,
  MySummaryResponse,
} from "../types";
import type { RoutingCtx } from "./routing";

const REFRESH_MS = 15_000;
const PROVIDERS_URL = "/api/me/providers";
const SUMMARY_URL = "/api/me/summary";
const ADMISSION_ATTEMPTS_URL = "/api/me/provider-admission-attempts";

async function settledJson<T>(
  result: PromiseSettledResult<Response>
): Promise<T | null> {
  if (result.status !== "fulfilled" || !result.value.ok) return null;
  try {
    return (await result.value.json()) as T;
  } catch {
    return null;
  }
}

interface FleetSnapshot {
  providers: MyProvidersResponse;
  summary: MySummaryResponse | null;
  attempts: HardwareAdmissionAttempt[] | null;
}

async function fetchFleetSnapshot(token: string): Promise<FleetSnapshot> {
  const headers = { Authorization: `Bearer ${token}` };
  const [providersResult, summaryResult, attemptsResult] =
    await Promise.allSettled([
      fetch(PROVIDERS_URL, { headers, cache: "no-store" }),
      fetch(SUMMARY_URL, { headers, cache: "no-store" }),
      fetch(ADMISSION_ATTEMPTS_URL, { headers, cache: "no-store" }),
    ]);
  if (providersResult.status !== "fulfilled" || !providersResult.value.ok) {
    const detail =
      providersResult.status === "fulfilled"
        ? `HTTP ${providersResult.value.status}`
        : providersResult.reason?.message || "network error";
    throw new Error(detail);
  }
  const providers =
    (await providersResult.value.json()) as MyProvidersResponse;
  const [summary, attemptBody] = await Promise.all([
    settledJson<MySummaryResponse>(summaryResult),
    settledJson<HardwareAdmissionAttemptsResponse>(attemptsResult),
  ]);
  return {
    providers,
    summary,
    attempts: attemptBody?.attempts ?? null,
  };
}

export interface FleetData {
  ready: boolean;
  authenticated: boolean;
  login: () => void;
  providersResp: MyProvidersResponse | null;
  summary: MySummaryResponse | null;
  admissionAttempts: HardwareAdmissionAttempt[];
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
  const { ready, authenticated, user, login, getAccessToken } = useAuth();
  const userID = (user as { id?: unknown } | null)?.id;
  const accountID =
    authenticated && typeof userID === "string" && userID.length > 0
      ? userID
      : null;
  const [providersResp, setProvidersResp] = useState<MyProvidersResponse | null>(null);
  const [summary, setSummary] = useState<MySummaryResponse | null>(null);
  const [admissionAttempts, setAdmissionAttempts] = useState<
    HardwareAdmissionAttempt[]
  >([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pollFailed, setPollFailed] = useState(false);
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);
  const [dataAccountID, setDataAccountID] = useState<string | null>(null);

  // Track whether we currently have data without retriggering fetchAll.
  const hasDataRef = useRef(false);
  const activeAccountRef = useRef<string | null>(accountID);
  activeAccountRef.current = accountID;

  const fetchAll = useCallback(async () => {
    const requestAccountID = accountID;
    if (!requestAccountID) return;
    setRefreshing(true);
    try {
      const token = await getAccessToken().catch(() => null);
      if (activeAccountRef.current !== requestAccountID) return;
      if (!token) {
        const hasData = hasDataRef.current;
        setError((current) => (hasData ? current : "Not authenticated"));
        setPollFailed(hasData);
        return;
      }
      const snapshot = await fetchFleetSnapshot(token);
      if (activeAccountRef.current !== requestAccountID) return;
      setProvidersResp(snapshot.providers);
      setDataAccountID(requestAccountID);
      hasDataRef.current = true;
      setError(null);
      setPollFailed(false);
      setLastUpdatedAt(Date.now());
      if (snapshot.summary) setSummary(snapshot.summary);
      if (snapshot.attempts) setAdmissionAttempts(snapshot.attempts);
    } catch (e) {
      if (activeAccountRef.current !== requestAccountID) return;
      const msg = e instanceof Error ? e.message : String(e);
      if (!hasDataRef.current) setError(msg);
      else setPollFailed(true);
    } finally {
      if (activeAccountRef.current === requestAccountID) {
        setLoading(false);
        setRefreshing(false);
      }
    }
  }, [accountID, getAccessToken]);

  // Clear account-scoped state on every identity transition. The return-value
  // owner gate below also hides it during the render before this effect runs.
  useEffect(() => {
    hasDataRef.current = false;
    setProvidersResp(null);
    setSummary(null);
    setAdmissionAttempts([]);
    setDataAccountID(null);
    setLoading(accountID !== null);
    setRefreshing(false);
    setError(null);
    setPollFailed(false);
    setLastUpdatedAt(null);
  }, [accountID]);

  // Poll only while the tab is visible; pause in the background (perf F6).
  useVisiblePolling(fetchAll, REFRESH_MS, accountID !== null);

  const ownsVisibleData =
    accountID !== null && dataAccountID === accountID;

  return {
    ready,
    authenticated,
    login,
    providersResp: ownsVisibleData ? providersResp : null,
    summary: ownsVisibleData ? summary : null,
    admissionAttempts: ownsVisibleData ? admissionAttempts : [],
    ctx: DEFAULT_CTX_FROM(ownsVisibleData ? providersResp : null),
    loading,
    refreshing,
    error,
    pollFailed,
    lastUpdatedAt,
    refetch: fetchAll,
  };
}
