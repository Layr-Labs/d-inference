"use client";

import { useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";

const PROVIDERS_URL = "/api/me/providers";

interface ProvidersResponse {
  providers?: Array<{ online?: boolean }>;
}

/**
 * True once we know the logged-in user has at least one provider machine
 * currently connected (online). Single fetch per session — this gates a
 * one-time popup, so polling would be wasted work.
 */
export function useIsConnectedProvider(enabled: boolean): boolean {
  const { authenticated, getAccessToken } = useAuth();
  const [isProvider, setIsProvider] = useState(false);

  useEffect(() => {
    if (!authenticated) {
      setIsProvider(false);
      return;
    }
    if (!enabled || isProvider) return;
    let cancelled = false;

    (async () => {
      try {
        const token = await getAccessToken();
        if (!token) return;
        const res = await fetch(PROVIDERS_URL, {
          headers: { Authorization: `Bearer ${token}` },
          cache: "no-store",
        });
        if (!res.ok) return;
        const data = (await res.json()) as ProvidersResponse;
        const online = (data.providers ?? []).some((p) => p.online);
        if (!cancelled && online) setIsProvider(true);
      } catch {
        // Best-effort: no popup on failure.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [enabled, authenticated, getAccessToken, isProvider]);

  return isProvider;
}
