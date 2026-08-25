"use client";

import { useEffect, useState } from "react";
import {
  fetchProviderRequirements,
  type ProviderRequirementsResponse,
} from "@/lib/api/provider-requirements";

export interface ProviderRequirementsState {
  status: "loading" | "ready" | "error";
  requirements: ProviderRequirementsResponse | null;
}

export function useProviderRequirements(): ProviderRequirementsState {
  const [state, setState] = useState<ProviderRequirementsState>({
    status: "loading",
    requirements: null,
  });

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    async function loadRequirements() {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
          const requirements = await fetchProviderRequirements(controller.signal);
          if (active) {
            setState({ status: "ready", requirements });
          }
          return;
        } catch {
          if (controller.signal.aborted) return;
        }
      }
      if (active) {
        setState({ status: "error", requirements: null });
      }
    }
    void loadRequirements();
    return () => {
      active = false;
      controller.abort();
    };
  }, []);

  return state;
}
