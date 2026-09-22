/** Coordinator verdicts only. OS reports, attested, and legacy trust flags do
 * not establish an App Attest authorization. Unix timestamps are seconds. */
export type VerificationState = "verified" | "pending" | "expired" | "revoked" | "unsupported" | "offline" | "unknown";
export interface VerificationPath { state: VerificationState; verified_at?: number; expires_at?: number }
export interface Verification {
  observed_at: number;
  app_attest: VerificationPath;
  legacy: VerificationPath;
}
export type VerificationMethod = "app_attest" | "legacy" | "dual" | "none";
export const LIVE_VERIFICATION_MAX_AGE_MS = 60_000;
const states = new Set<VerificationState>(["verified", "pending", "expired", "revoked", "unsupported", "offline", "unknown"]);

function validPath(value: unknown): value is VerificationPath {
  if (!value || typeof value !== "object") return false;
  const p = value as VerificationPath;
  return states.has(p.state) && [p.verified_at, p.expires_at].every((v) => v === undefined || (Number.isFinite(v) && v > 0));
}

export function isVerification(value: unknown): value is Verification {
  if (!value || typeof value !== "object") return false;
  const v = value as Verification;
  return Number.isFinite(v.observed_at) && v.observed_at > 0 && validPath(v.app_attest) && validPath(v.legacy);
}

export function parseVerification(raw: string | null): Verification | undefined {
  if (!raw) return undefined;
  try {
    const v = JSON.parse(raw) as Verification;
    if (!isVerification(v)) return undefined;
    return v;
  } catch { return undefined; }
}

export function currentVerification(v: Verification | undefined, now = Date.now()): Verification | undefined {
  if (!isVerification(v)) return undefined;
  const age = now - v.observed_at * 1000;
  const path = (p: VerificationPath): VerificationPath => {
    if (p.state !== "verified") return p;
    if (!p.expires_at || p.expires_at * 1000 <= now) return { ...p, state: "expired" };
    if (age < 0 || age >= LIVE_VERIFICATION_MAX_AGE_MS) return { ...p, state: "unknown" };
    return p;
  };
  return { ...v, app_attest: path(v.app_attest), legacy: path(v.legacy) };
}

/** Historical verdicts are judged at dispatch, never against today's clock. */
export function verificationPresentation(v: Verification | undefined) {
  if (!isVerification(v)) v = undefined;
  const at = v?.observed_at ?? 0;
  const verified = (p?: VerificationPath) => p?.state === "verified" && at > 0 &&
    // The coordinator has already checked the precise dispatch instant.
    // Unix-second serialization can round a still-valid expiry down to the
    // same second as observed_at; keep that historical verified verdict.
    typeof p.verified_at === "number" && p.verified_at <= at && typeof p.expires_at === "number" && p.expires_at >= at;
  const appAttest = verified(v?.app_attest), legacy = verified(v?.legacy);
  let method: VerificationMethod = "none";
  if (appAttest && legacy) method = "dual";
  else if (appAttest) method = "app_attest";
  else if (legacy) method = "legacy";
  const labels = { app_attest: "Verified via App Attest", legacy: "Verified via legacy authorization", dual: "Verified via App Attest + legacy", none: "Verification unavailable" };
  let label = labels[method];
  if (method === "none" && v) {
    const priority: VerificationState[] = ["offline", "revoked", "expired", "pending", "unsupported", "unknown"];
    const state = priority.find((s) => v.app_attest.state === s || v.legacy.state === s) ?? "unknown";
    const statusLabels = { offline: "Offline", revoked: "Verification revoked", expired: "Verification expired", pending: "Verification pending", unsupported: "Verification unsupported", unknown: "Verification unavailable", verified: labels.none };
    label = statusLabels[state];
  }
  return { method, appAttest, legacy, verified: method !== "none", label };
}

export function hasUsableVerification(v: Verification | undefined, now = Date.now()): boolean {
  if (!isVerification(v)) return false;
  const age = now - v.observed_at * 1000;
  if (age < 0 || age >= LIVE_VERIFICATION_MAX_AGE_MS) return false;
  const current = currentVerification(v, now)!;
  return verificationPresentation(current).verified ||
    (current.app_attest.state !== "unknown" && current.legacy.state !== "unknown");
}

export function summarizeVerification(providers: { verification?: Verification }[], now = Date.now()) {
  const counts = { authorized: 0, appAttest: 0, legacy: 0, overlap: 0, total: providers.length, known: 0, unknown: 0 };
  for (const p of providers) {
    if (!hasUsableVerification(p.verification, now)) { counts.unknown++; continue; }
    counts.known++;
    const v = verificationPresentation(currentVerification(p.verification, now));
    if (v.verified) counts.authorized++;
    if (v.appAttest) counts.appAttest++;
    if (v.legacy) counts.legacy++;
    if (v.method === "dual") counts.overlap++;
  }
  return counts;
}

export function verificationCountLabel(c: ReturnType<typeof summarizeVerification>): string {
  return c.total > 0 && c.known === 0 ? "Unavailable" : `${c.authorized} / ${c.known}`;
}
