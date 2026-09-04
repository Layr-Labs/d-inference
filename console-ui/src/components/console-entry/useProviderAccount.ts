"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { summarizeProviders, type ProviderAccount } from "./workspaces";

const EMPTY = { total: 0, online: 0 };

/** Account discovery is separate from inference-key provisioning and never persisted. */
export function useProviderAccount(enabled: boolean) {
  const { ready, authenticated, user, getAccessToken } = useAuthContext();
  const tokenGetter = useRef(getAccessToken);
  useEffect(() => { tokenGetter.current = getAccessToken; }, [getAccessToken]);
  const accountId = user && typeof user === "object" && "id" in user ? String(user.id) : null;
  const [result, setResult] = useState<{ accountId: string | null; value: ProviderAccount } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const retry = useCallback(() => setAttempt((value) => value + 1), []);

  useEffect(() => {
    setResult(null);
    if (!enabled || !ready || !authenticated) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    let pending = false;
    let disposed = false;
    const load = async () => {
      if (pending || disposed) return;
      pending = true;
      const request = new AbortController();
      const signal = AbortSignal.any([controller.signal, request.signal]);
      timer = setTimeout(() => {
        request.abort();
        if (!disposed) setResult({ accountId, value: { ...EMPTY, status: "error" } });
      }, 15_000);
      try {
        const token = await tokenGetter.current();
        if (signal.aborted) return;
        if (!token) throw new Error("No session");
        const response = await fetch("/api/me/providers", { headers: { Authorization: `Bearer ${token}` }, cache: "no-store", signal });
        if (!response.ok) throw new Error("Provider lookup failed");
        const value = summarizeProviders(await response.json());
        if (!signal.aborted) setResult({ accountId, value });
      } catch {
        if (!signal.aborted) setResult({ accountId, value: { ...EMPTY, status: "error" } });
      } finally {
        clearTimeout(timer);
        pending = false;
      }
    };
    void load();
    const onVisible = () => { if (document.visibilityState === "visible") void load(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      disposed = true;
      controller.abort();
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [enabled, ready, authenticated, accountId, attempt]);

  let account: ProviderAccount = { ...EMPTY, status: "loading" };
  if (ready && !authenticated) account = { ...EMPTY, status: "guest" };
  else if (ready && authenticated && result?.accountId === accountId) account = result.value;
  return { account, retry };
}
