"use client";

import { useEffect, useRef, useState } from "react";
import { isModelDemandResponse, type DemandWindow, type ModelDemandResponse } from "./types";

export function useModelDemand(window: DemandWindow, refreshToken: string | null) {
  const [data, setData] = useState<ModelDemandResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const displayedWindow = useRef<DemandWindow | null>(null);
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(displayedWindow.current !== window);
    setError(false);
    async function load() {
      try {
        const response = await fetch(`/api/network/model-demand?window=${window}`, {
          cache: "no-store", signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15_000)]),
        });
        if (!response.ok) throw new Error("Demand unavailable");
        const value: unknown = await response.json();
        if (!isModelDemandResponse(value, window)) throw new Error("Invalid demand snapshot");
        if (!controller.signal.aborted) { setData(value); displayedWindow.current = window; }
      } catch {
        if (!controller.signal.aborted) setError(true);
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }
    void load();
    return () => controller.abort();
  }, [window, refreshToken, revision]);
  return { data: data?.window === window ? data : null, loading, error, retry: () => setRevision(v => v + 1) };
}
