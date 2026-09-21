import { afterEach, expect, it, vi } from "vitest";
import { act, cleanup, render, renderHook, screen } from "@testing-library/react";
import { currentVerification, parseVerification, summarizeVerification, verificationPresentation, type Verification, type VerificationState } from "./verification";
import { extractTrustMeta } from "./chat/stream";
import { TrustBadge } from "@/components/TrustBadge";
import { ProofDetails } from "@/components/verification/ProofDetails";
import { useCurrentAuthorizations } from "@/app/providers/dashboard/useCurrentAuthorizations";
import { makeProvider } from "@/app/providers/dashboard/testFixtures";
import { matchesTrustFilter } from "@/app/stats/provider-fleet";
import { hardwareProvider } from "@/app/stats/hardware/hardware-test-fixtures";

const now = 1790000000;
const path = { state: "verified" as const, verified_at: now - 10, expires_at: now + 30 };
const snapshot = (app: VerificationState = "verified", legacy: VerificationState = "pending"): Verification => ({
  observed_at: now, app_attest: { ...path, state: app }, legacy: { ...path, state: legacy },
});
afterEach(() => { cleanup(); vi.useRealTimers(); });

it("carries a self_signed App Attest verdict from response headers to chat without inferring from attested", () => {
  const trust = extractTrustMeta(new Response(null, { headers: {
    "x-provider-trust-level": "self_signed", "x-provider-attested": "true",
    "x-provider-verification": JSON.stringify(snapshot()), "x-provider-encrypted": "true",
  } }));
  render(<TrustBadge trust={trust} />);
  expect(screen.getByText("Verified via App Attest")).toBeInTheDocument();
  expect(trust.trustLevel).toBe("self_signed");
  expect(trust.encrypted).toBe(true);
  expect(extractTrustMeta(new Response(null, { headers: { "x-provider-attested": "true", "x-provider-trust-level": "hardware" } })).verification).toBeUndefined();
  expect(parseVerification('{"app_attest":true}')).toBeUndefined();
});

it.each<[VerificationState, string]>([["pending", "Verification pending"], ["expired", "Verification expired"], ["revoked", "Verification revoked"], ["unsupported", "Verification unsupported"], ["offline", "Offline"]])("labels %s without a verified count", (state, label) => {
  const v = snapshot(state, state);
  expect(verificationPresentation(v)).toMatchObject({ verified: false, label });
  expect(summarizeVerification([{ verification: v }]).authorized).toBe(0);
});

it("counts the union once and filters each method independently", () => {
  vi.useFakeTimers(); vi.setSystemTime(now * 1000);
  const providers = [snapshot(), snapshot("pending", "verified"), snapshot("verified", "verified"), snapshot("revoked", "revoked")].map((verification) => ({ verification }));
  expect(summarizeVerification(providers)).toEqual({ authorized: 3, appAttest: 2, legacy: 2, overlap: 1, total: 4 });
  const dual = hardwareProvider({ verification: providers[2].verification, trust_level: "self_signed" });
  for (const filter of ["verified", "app_attest", "legacy", "dual"] as const) expect(matchesTrustFilter(dual, filter)).toBe(true);
  expect(matchesTrustFilter(dual, "basic")).toBe(false);
});

it("expires live grants and stale cached checks without rewriting a historical response", () => {
  vi.useFakeTimers(); vi.setSystemTime(now * 1000);
  const v = snapshot();
  const providers = [makeProvider({ verification: v, app_attest_authorized: true, online: true })];
  const { result, rerender } = renderHook(({ providers }) => useCurrentAuthorizations(providers), { initialProps: { providers } });
  act(() => vi.advanceTimersByTime(30000));
  expect(result.current[0].verification?.app_attest.state).toBe("expired");
  expect(verificationPresentation(v).verified).toBe(true);
  expect(currentVerification({ ...v, app_attest: { ...path, expires_at: now + 1000 } }, (now + 61) * 1000)?.app_attest.state).toBe("unknown");
  rerender({ providers: [makeProvider({ verification: snapshot("revoked", "revoked"), online: true })] });
  expect(result.current[0].app_attest_authorized).toBe(false);
});

it("explains the proof boundary, unknown details, and historical freshness", () => {
  render(<ProofDetails verification={snapshot()} historical />);
  expect(screen.getByText(/not the provider’s current authorization/)).toBeInTheDocument();
  expect(screen.getByText(/does not independently validate Apple certificates/)).toBeInTheDocument();
  expect(screen.getAllByText("Not published")).toHaveLength(3);
  expect(screen.getByText(/do not certify reported RAM/)).toBeInTheDocument();
});
