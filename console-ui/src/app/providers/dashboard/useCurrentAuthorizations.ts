"use client";

import { useEffect, useMemo, useState } from "react";
import type { MyProvider } from "../types";
import { hasCurrentAppAttestAuthorization } from "../authorization";

/** Expire cached grants even when the next fleet poll fails or is delayed. */
export function useCurrentAuthorizations(providers: MyProvider[]): MyProvider[] {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const deadlines = providers
      .filter((p) => p.app_attest_authorized)
      .map((p) => (p.authorization_expires_at ?? 0) * 1000)
      .filter((deadline) => Number.isFinite(deadline) && deadline > now);
    if (deadlines.length === 0) return;
    const delay = Math.max(0, Math.min(...deadlines) - Date.now());
    const timer = setTimeout(() => setNow(Date.now()), Math.min(delay + 1, 2_147_483_647));
    return () => clearTimeout(timer);
  }, [providers, now]);

  return useMemo(() => providers.map((p) => (
    p.app_attest_authorized && !hasCurrentAppAttestAuthorization(p, now)
      ? { ...p, app_attest_authorized: false }
      : p
  )), [providers, now]);
}
