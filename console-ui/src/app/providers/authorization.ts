import { currentVerification, verificationPresentation } from "@/lib/verification";
import type { MyProvider } from "./types";

/** Display-only guidance. The coordinator independently checks each dispatch. */
export function hasCurrentAppAttestAuthorization(p: MyProvider, nowMs = Date.now()): boolean {
  if (p.verification) return p.online && (p.status === "online" || p.status === "serving") && p.runtime_verified && verificationPresentation(currentVerification(p.verification, nowMs)).appAttest;
  const expires = p.authorization_expires_at;
  return p.online && (p.status === "online" || p.status === "serving") && p.runtime_verified &&
    p.app_attest_authorized === true && typeof expires === "number" && Number.isFinite(expires) &&
    expires * 1000 > nowMs;
}
