"use client";

import { useEffect, useState } from "react";
import {
  fetchProviderRequirements,
  type ProviderRequirementsResponse,
} from "@/lib/api/provider-requirements";

export function useProviderRequirements() {
  const [requirements, setRequirements] =
    useState<ProviderRequirementsResponse | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    fetchProviderRequirements(controller.signal)
      .then(setRequirements)
      .catch(() => {
        // The coordinator remains authoritative at registration. Keeping the
        // static setup fallback visible is better than hiding setup entirely
        // during a transient public-requirements outage.
      });
    return () => controller.abort();
  }, []);

  return requirements;
}
