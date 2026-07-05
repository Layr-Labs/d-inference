"use client";

import { useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";

// One-shot check for whether the signed-in account has at least one linked
// provider machine. Drives progressive disclosure of the Setup/Earnings tabs in
// the providers layout, which are only meaningful post-install.
//
// Deliberately starts `false` and only reads state inside an effect (never
// during render) so the first client render matches the server (Dashboard-only)
// — the same hydration-determinism discipline as the store/InviteCodeBanner fix
// in #457. Non-polling and best-effort: an unauthenticated session or a failed
// fetch leaves the tabs hidden, which self-heals on the next load.
export function useHasLinkedProviders(): boolean {
  const { authenticated, getAccessToken } = useAuth();
  const [hasProviders, setHasProviders] = useState(false);

  useEffect(() => {
    if (!authenticated) {
      setHasProviders(false);
      return;
    }
    let cancelled = false;
    void (async () => {
      const token = await getAccessToken().catch(() => null);
      if (!token || cancelled) return;
      try {
        const res = await fetch("/api/me/providers", {
          headers: { Authorization: `Bearer ${token}` },
          cache: "no-store",
        });
        if (!res.ok || cancelled) return;
        const data = (await res.json()) as { providers?: unknown[] };
        if (!cancelled) {
          setHasProviders(Array.isArray(data.providers) && data.providers.length > 0);
        }
      } catch {
        // Best-effort: leave the tabs hidden on failure.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [authenticated, getAccessToken]);

  return hasProviders;
}
