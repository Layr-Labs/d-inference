"use client";

import { useEffect, useState } from "react";
import { isVerification, LIVE_VERIFICATION_MAX_AGE_MS } from "@/lib/verification";
import type { PlatformStats } from "./platform-types";

/** Stats snapshots change only at an authorization expiry or cache-age boundary. */
export function nextVerificationTransition(stats: PlatformStats | null, now: number): number | null {
  if (!stats) return null;
  let next = Number.POSITIVE_INFINITY;
  for (const provider of stats.providers) {
    const verdict = provider.verification;
    if (!isVerification(verdict)) continue;
    if (verdict.app_attest.state !== "verified" && verdict.legacy.state !== "verified") continue;
    for (const boundary of [
      verdict.observed_at * 1000,
      verdict.observed_at * 1000 + LIVE_VERIFICATION_MAX_AGE_MS,
      verdict.app_attest.state === "verified" ? (verdict.app_attest.expires_at ?? Number.POSITIVE_INFINITY) * 1000 : Number.POSITIVE_INFINITY,
      verdict.legacy.state === "verified" ? (verdict.legacy.expires_at ?? Number.POSITIVE_INFINITY) * 1000 : Number.POSITIVE_INFINITY,
    ]) {
      if (Number.isFinite(boundary) && boundary > now && boundary < next) next = boundary;
    }
  }
  return Number.isFinite(next) ? next : null;
}

/** Wake at the next visible verdict change, plus focus and tab restoration. */
export function useStatsVerificationClock(stats: PlatformStats | null, refreshedAt: number) {
  const [tickAt, setTickAt] = useState(() => Date.now());
  // A newly fetched snapshot must be evaluated at the current render time,
  // even when the previous snapshot had no pending transition to wake us.
  const now = Math.max(tickAt, refreshedAt);
  useEffect(() => {
    const tick = () => setTickAt(Date.now());
    const boundary = nextVerificationTransition(stats, now);
    const timer = boundary === null ? null : setTimeout(tick, Math.max(1, boundary - now));
    window.addEventListener("focus", tick);
    document.addEventListener("visibilitychange", tick);
    return () => {
      if (timer !== null) clearTimeout(timer);
      window.removeEventListener("focus", tick);
      document.removeEventListener("visibilitychange", tick);
    };
  }, [stats, now]);
  return now;
}
