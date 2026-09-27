"use client";
import { useMemo } from "react";
import type { MyProvider } from "../types";
import { hasCurrentAppAttestAuthorization } from "../authorization";
import { currentVerification } from "@/lib/verification";
import { useVerificationClock } from "@/hooks/useVerificationClock";

/** Expire both methods even while polling fails; preserve historical evidence. */
export function useCurrentAuthorizations(providers: MyProvider[]): MyProvider[] {
  const now = useVerificationClock();
  return useMemo(() => providers.map((p) => ({ ...p,
    verification: currentVerification(p.verification, now),
    app_attest_authorized: hasCurrentAppAttestAuthorization(p, now),
  })), [providers, now]);
}
