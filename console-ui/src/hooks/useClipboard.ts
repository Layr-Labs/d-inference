"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export type CopyStatus = "idle" | "copying" | "copied" | "error";

/** Clipboard feedback belongs to the current attempt, not a stale tab or view. */
export function useClipboard() {
  const [status, setStatus] = useState<CopyStatus>("idle");
  const attempt = useRef(0);
  const reset = useCallback(() => {
    attempt.current += 1;
    setStatus("idle");
  }, []);

  useEffect(() => () => { attempt.current += 1; }, []);
  useEffect(() => {
    if (status !== "copied") return;
    const timer = setTimeout(reset, 2000);
    return () => clearTimeout(timer);
  }, [status, reset]);

  const copy = useCallback(async (text: string) => {
    const current = ++attempt.current;
    setStatus("copying");
    try {
      await navigator.clipboard.writeText(text);
      if (attempt.current === current) setStatus("copied");
    } catch {
      if (attempt.current === current) setStatus("error");
    }
  }, []);

  return { status, copy, reset };
}
