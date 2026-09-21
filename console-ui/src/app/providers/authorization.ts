import { currentVerification, summarizeVerification, verificationPresentation } from "@/lib/verification";
import type { MyProvider } from "./types";

/** Display-only guidance. The coordinator independently checks each dispatch. */
export function hasCurrentAppAttestAuthorization(p: MyProvider, nowMs = Date.now()): boolean {
  if (p.verification) return p.online && (p.status === "online" || p.status === "serving") && p.runtime_verified && verificationPresentation(currentVerification(p.verification, nowMs)).appAttest;
  const expires = p.authorization_expires_at;
  return p.online && (p.status === "online" || p.status === "serving") && p.runtime_verified &&
    p.app_attest_authorized === true && typeof expires === "number" && Number.isFinite(expires) &&
    expires * 1000 > nowMs;
}


/** Compatibility verdicts retain their unknown proof/observation timestamps. */
export function ownerVerificationPresentation(p: MyProvider, now = Date.now()) {
  if (p.verification) return verificationPresentation(currentVerification(p.verification, now));
  if (hasCurrentAppAttestAuthorization(p, now)) return {
    method: "app_attest" as const, appAttest: true, legacy: false, verified: true, label: "Verified via App Attest",
  };
  return verificationPresentation(undefined);
}

export function summarizeOwnerVerification(providers: MyProvider[]) {
  const counts = summarizeVerification(providers);
  for (const p of providers) {
    if (!p.verification && hasCurrentAppAttestAuthorization(p)) {
      counts.unknown--; counts.known++; counts.authorized++; counts.appAttest++;
    }
  }
  return counts;
}
