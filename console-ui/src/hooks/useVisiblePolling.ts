"use client";

import { useEffect, useRef } from "react";

/**
 * Run `callback` immediately and then on an interval, but ONLY while the tab is
 * visible. When the tab is hidden the interval is paused (no dead background
 * traffic); when it becomes visible again the callback fires once immediately
 * and the interval resumes (perf F6).
 *
 * The callback is held in a ref so a changing callback identity (e.g. a fetch
 * closure that depends on an access token) does not tear down and re-arm the
 * interval. Pass `enabled = false` to suspend polling entirely.
 */
export function useVisiblePolling(
  callback: () => void,
  intervalMs: number,
  enabled = true,
): void {
  const cbRef = useRef(callback);
  // Keep the ref pointed at the latest callback without re-arming the interval.
  useEffect(() => {
    cbRef.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!enabled) return;

    // Initial load runs regardless of visibility (matches prior on-mount fetch).
    cbRef.current();

    let intervalId: ReturnType<typeof setInterval> | undefined;
    const start = () => {
      if (intervalId === undefined) {
        intervalId = setInterval(() => cbRef.current(), intervalMs);
      }
    };
    const stop = () => {
      if (intervalId !== undefined) {
        clearInterval(intervalId);
        intervalId = undefined;
      }
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        cbRef.current();
        start();
      } else {
        stop();
      }
    };

    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [intervalMs, enabled]);
}
