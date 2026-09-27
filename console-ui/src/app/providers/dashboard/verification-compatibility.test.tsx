import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { AppAttestPanel } from "./AppAttestPanel";
import { TrustFooter } from "./TrustFooter";
import { makeProvider } from "./testFixtures";
import { ownerVerificationPresentation, summarizeOwnerVerification } from "../authorization";
import { providerRouteReason } from "@/app/stats/provider-fleet";
import { hardwareProvider } from "@/app/stats/hardware/hardware-test-fixtures";

afterEach(() => { cleanup(); vi.useRealTimers(); });
const now = 1790000000;

it("keeps a connected revoked machine in the connection denominator", () => {
  vi.useFakeTimers(); vi.setSystemTime(now * 1000);
  render(<TrustFooter providers={[makeProvider({ online: false, status: "untrusted", verification: {
    observed_at: now, app_attest: { state: "revoked" }, legacy: { state: "revoked" },
  } })]} />);
  expect(screen.getByText(/0 currently authorized of 1 connected machines/)).toBeInTheDocument();
});

it("preserves explicit compatibility authorization without inventing proof timestamps", () => {
  vi.useFakeTimers(); vi.setSystemTime(now * 1000);
  const provider = makeProvider({ online: true, status: "online", trust_level: "self_signed",
    app_attest_authorized: true, authorization_expires_at: now + 30, verification: undefined });
  render(<AppAttestPanel provider={provider} />);
  expect(screen.getByText("Verified via App Attest")).toBeInTheDocument();
  expect(screen.getByText(/Verification time, certificate, receipt and qualified-build details are unavailable/)).toBeInTheDocument();
  expect(ownerVerificationPresentation(provider).verified).toBe(true);
  expect(summarizeOwnerVerification([provider])).toMatchObject({ authorized: 1, known: 1, unknown: 0 });
  vi.setSystemTime((now + 31) * 1000);
  expect(ownerVerificationPresentation(provider).verified).toBe(false);
});

it("does not describe App Attest authorization as legacy hardware or challenge evidence", () => {
  const reason = providerRouteReason(hardwareProvider({ trust_level: "self_signed", last_challenge_verified: "", verification: {
    observed_at: now, app_attest: { state: "verified", verified_at: now - 1, expires_at: now + 60 }, legacy: { state: "pending" },
  } }), now * 1000);
  expect(reason).toContain("Verified via App Attest");
  expect(reason).not.toContain("hardware, runtime, and challenge");
  expect(reason).toContain("Routing eligibility is not published");
});
