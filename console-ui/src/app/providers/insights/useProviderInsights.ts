"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
import type { ProviderInsights } from "./types";

interface Snapshot { key: string; data: ProviderInsights | null; error: string | null }

export function useProviderInsights(window: "7d" | "30d" = "7d") {
  const { ready, authenticated, user, getAccessToken } = useAuth();
  const id = (user as { id?: string } | null)?.id ?? "authenticated";
  const key = ready && authenticated ? `${id}:${window}` : "";
  const [snapshot, setSnapshot] = useState<Snapshot>({ key: "", data: null, error: null });
  const session = useRef<{ key: string; request: AbortController | null } | null>(null);
  const getToken = useRef(getAccessToken);
  useEffect(() => { getToken.current = getAccessToken; }, [getAccessToken]);

  const refresh = useCallback(async () => {
    const current = session.current;
    if (!current || current.key !== key || current.request) return;
    const request = new AbortController();
    current.request = request;
    const valid = () => session.current === current && !request.signal.aborted;
    try {
      const token = await getToken.current();
      if (!valid()) return;
      if (!token) throw new Error("Sign in again to load your insights.");
      const response = await fetch(`/api/me/provider-insights?window=${window}`, {
        headers: { Authorization: `Bearer ${token}` }, cache: "no-store", signal: AbortSignal.any([request.signal, AbortSignal.timeout(20_000)]),
      });
      if (!response.ok) throw new Error(response.status === 404 ? "Detailed analytics are awaiting a coordinator update." : "Could not refresh your insights.");
      const data = await response.json() as ProviderInsights;
      if (!data.lifetime || !data.totals || !Array.isArray(data.days) || !Array.isArray(data.models) || !Array.isArray(data.machines) || data.window !== window) throw new Error("Invalid insights response.");
      if (valid()) setSnapshot({ key, data, error: null });
    } catch (error) {
      if (valid()) setSnapshot(previous => ({ key, data: previous.key === key ? previous.data : null, error: error instanceof Error ? error.message : "Could not load insights." }));
    } finally {
      if (session.current === current) current.request = null;
    }
  }, [key, window]);

  useEffect(() => {
    if (!key) return;
    const current = { key, request: null as AbortController | null };
    session.current = current;
    void refresh();
    return () => { current.request?.abort(); if (session.current === current) session.current = null; };
  }, [key, refresh]);
  useVisiblePolling(refresh, 30_000, !!key);
  const current = snapshot.key === key ? snapshot : { data: null, error: null };
  return { ...current, loading: !!key && !current.data && !current.error, refresh };
}
