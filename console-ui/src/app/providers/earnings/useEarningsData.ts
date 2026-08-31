"use client";

// Data hook for the earnings page: auth headers, fetch via the same-origin
// proxy, and visible-tab polling. The only file that touches the network.

import { useCallback, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
import { STORAGE_KEYS } from "@/lib/constants";
import type { EarningsResponse } from "./types";
import { makeScenario, type ScenarioName } from "./testFixtures";

// Dev-only fixture preview: NEXT_PUBLIC_EARNINGS_FIXTURE=TYPICAL (or another
// scenario name) renders local fixture data instead of fetching. Never active
// in production builds.
const SCENARIO_NAMES: ScenarioName[] = [
  "EMPTY",
  "TYPICAL",
  "TRUNCATED",
  "CREDITS_ONLY",
  "BELOW_MIN_WITHDRAW",
  "WHALE",
];

function fixtureScenario(): ScenarioName | undefined {
  if (process.env.NODE_ENV === "production") return undefined;
  const raw = process.env.NEXT_PUBLIC_EARNINGS_FIXTURE;
  if (!raw) return undefined;
  // Any truthy but unknown value still previews something instead of a blank page.
  return SCENARIO_NAMES.includes(raw as ScenarioName)
    ? (raw as ScenarioName)
    : "TYPICAL";
}

const FIXTURE_SCENARIO = fixtureScenario();

export interface EarningsData {
  data: EarningsResponse | null;
  loading: boolean;
  error: string | null;
  /** True when the failure was an auth failure (401/403), not a server fault. */
  unauthorized: boolean;
  refetch: () => Promise<void>;
}

export function useEarningsData(authenticated: boolean): EarningsData {
  const { getAccessToken } = useAuth();
  const [data, setData] = useState<EarningsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [unauthorized, setUnauthorized] = useState(false);

  const getAuthHeaders = useCallback(async (): Promise<Record<string, string>> => {
    const accessToken = await getAccessToken().catch(() => null);
    if (accessToken) {
      return { Authorization: `Bearer ${accessToken}` };
    }
    const apiKey = localStorage.getItem(STORAGE_KEYS.apiKey) || "";
    return apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
  }, [getAccessToken]);

  const refetch = useCallback(async () => {
    if (FIXTURE_SCENARIO) {
      setData(makeScenario(FIXTURE_SCENARIO, Date.now()));
      setLoading(false);
      return;
    }
    setError(null);
    setUnauthorized(false);
    try {
      // Same-origin proxy (perf F9): no cross-origin preflight, coordinator
      // URL resolved server-side.
      const headers = await getAuthHeaders();
      const res = await fetch(`/api/me/earnings?limit=100`, { headers });
      if (!res.ok) {
        setUnauthorized(res.status === 401 || res.status === 403);
        throw new Error(`HTTP ${res.status}`);
      }
      setData(await res.json());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [getAuthHeaders]);

  // Poll only while the tab is visible (perf F6).
  useVisiblePolling(refetch, 30_000, authenticated);

  return { data, loading, error, unauthorized, refetch };
}
