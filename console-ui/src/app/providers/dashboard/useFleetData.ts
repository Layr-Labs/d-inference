"use client";

// Account-scoped fleet data. Polls every 15s while visible and retains prior
// data only within the same session; account changes cancel pending work.

import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
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

type FleetSnapshot = Pick<FleetData,
  "providersResp" | "summary" | "loading" | "refreshing" | "error" | "pollFailed" | "lastUpdatedAt"
> & { accountKey: string | null };

interface FleetSession {
  accountKey: string;
  inFlight: AbortController | null;
}

function emptySnapshot(accountKey: string | null): FleetSnapshot {
  return {
    accountKey,
    providersResp: null,
    summary: null,
    loading: accountKey !== null,
    refreshing: false,
    error: null,
    pollFailed: false,
    lastUpdatedAt: null,
  };
}

const DEFAULT_CTX_FROM = (resp: MyProvidersResponse | null): RoutingCtx => ({
  latest_provider_version: resp?.latest_provider_version ?? "",
  min_provider_version: resp?.min_provider_version ?? "",
  heartbeat_timeout_seconds: resp?.heartbeat_timeout_seconds ?? 90,
  challenge_max_age_seconds: resp?.challenge_max_age_seconds ?? 360,
});

async function readProviders(result: PromiseSettledResult<Response>): Promise<MyProvidersResponse> {
  if (result.status !== "fulfilled") throw new Error(result.reason?.message || "network error");
  if (!result.value.ok) throw new Error(`HTTP ${result.value.status}`);
  const providers = (await result.value.json()) as MyProvidersResponse;
  // A malformed success is not proof that the account has no machines.
  if (!Array.isArray(providers?.providers)) throw new Error("Invalid provider response");
  return providers;
}

async function readSummary(result: PromiseSettledResult<Response>): Promise<MySummaryResponse | undefined> {
  if (result.status !== "fulfilled" || !result.value.ok) return;
  try {
    return (await result.value.json()) as MySummaryResponse;
  } catch {
    // Missing summary data must not hide a successfully loaded fleet.
    return;
  }
}

export function useFleetData(): FleetData {
  const { ready, authenticated, login, getAccessToken, user } = useAuth();
  const userID = (user as { id?: unknown } | null)?.id;
  const identity = typeof userID === "string" ? userID : "authenticated";
  const accountKey = ready && authenticated ? identity : null;
  const [snapshot, setSnapshot] = useState(() => emptySnapshot(accountKey));
  const sessionRef = useRef<FleetSession | null>(null);
  const tokenGetterRef = useRef(getAccessToken);

  // Getter identity is not an account change. Keep the latest implementation
  // without resetting a session when an auth adapter recreates its functions.
  useEffect(() => {
    tokenGetterRef.current = getAccessToken;
  }, [getAccessToken]);

  const fetchAll = useCallback(async () => {
    const session = sessionRef.current;
    if (!session || session.accountKey !== accountKey || session.inFlight) return;
    const controller = new AbortController();
    session.inFlight = controller;
    const isCurrent = () => sessionRef.current === session && !controller.signal.aborted;
    setSnapshot((previous) => ({ ...previous, refreshing: true }));

    try {
      const token = await tokenGetterRef.current().catch(() => null);
      if (!isCurrent()) return;
      if (!token) throw new Error("Not authenticated");
      const options = {
        headers: { Authorization: `Bearer ${token}` },
        cache: "no-store" as const,
        signal: controller.signal,
      };

      // Providers is required; summary is best-effort.
      const [pRes, sRes] = await Promise.allSettled([
        fetch(PROVIDERS_URL, options),
        fetch(SUMMARY_URL, options),
      ]);
      if (!isCurrent()) return;
      const providers = await readProviders(pRes);
      if (!isCurrent()) return;
      setSnapshot((previous) => ({
        ...previous,
        providersResp: providers,
        error: null,
        pollFailed: false,
        lastUpdatedAt: Date.now(),
      }));

      const summary = await readSummary(sRes);
      if (isCurrent() && summary !== undefined) setSnapshot((previous) => ({ ...previous, summary }));
    } catch (e) {
      if (!isCurrent()) return;
      const message = e instanceof Error ? e.message : String(e);
      setSnapshot((previous) => previous.providersResp
        ? { ...previous, pollFailed: true }
        : { ...previous, error: message });
    } finally {
      if (isCurrent()) {
        session.inFlight = null;
        setSnapshot((previous) => ({ ...previous, loading: false, refreshing: false }));
      }
    }
  }, [accountKey]);

  useEffect(() => {
    setSnapshot(emptySnapshot(accountKey));
    if (accountKey === null) return;
    const session: FleetSession = { accountKey, inFlight: null };
    sessionRef.current = session;
    // An authenticated account switch does not re-arm useVisiblePolling.
    // Start its first load here; the in-flight guard coalesces the mount poll.
    void fetchAll();
    return () => {
      session.inFlight?.abort();
      if (sessionRef.current === session) sessionRef.current = null;
    };
  }, [accountKey, fetchAll]);

  useVisiblePolling(fetchAll, REFRESH_MS, accountKey !== null);

  // Hide the previous account's data on the very first render, before effects
  // reset state. Signing in must show loading rather than empty onboarding.
  const current = snapshot.accountKey === accountKey ? snapshot : emptySnapshot(accountKey);
  return {
    ready,
    authenticated,
    login,
    providersResp: current.providersResp,
    summary: current.summary,
    ctx: DEFAULT_CTX_FROM(current.providersResp),
    loading: current.loading,
    refreshing: current.refreshing,
    error: current.error,
    pollFailed: current.pollFailed,
    lastUpdatedAt: current.lastUpdatedAt,
    refetch: fetchAll,
  };
}
