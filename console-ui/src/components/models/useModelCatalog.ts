"use client";

import { useCallback, useEffect, useState } from "react";
import { fetchModels, fetchPricing, type Model, type PricingResponse } from "@/lib/api";

export function useModelCatalog() {
  const [models, setModels] = useState<Model[]>([]);
  const [pricing, setPricing] = useState<PricingResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [modelsError, setModelsError] = useState(false);
  const [pricingError, setPricingError] = useState(false);
  const [revision, setRevision] = useState(0);
  const refresh = useCallback(() => setRevision((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    async function load() {
      const [catalogResult, pricingResult] = await Promise.allSettled([fetchModels(), fetchPricing()]);
      if (cancelled) return;
      setModelsError(catalogResult.status === "rejected");
      setPricingError(pricingResult.status === "rejected");
      if (catalogResult.status === "fulfilled") setModels(catalogResult.value);
      // Do not show stale rates as current prices after a refresh failure.
      setPricing(pricingResult.status === "fulfilled" ? pricingResult.value : null);
      setLoading(false);
    }

    void load();
    return () => { cancelled = true; };
  }, [revision]);

  return { models, pricing, loading, modelsError, pricingError, refresh };
}
