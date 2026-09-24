import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, render, renderHook, screen } from "@testing-library/react";
import { hasCurrentAppAttestAuthorization } from "../authorization";
import { computeWarnings } from "../warnings";
import { AttestationPanel } from "./AttestationPanel";
import { DEFAULT_CTX, routingFor } from "./routing";
import { makeProvider } from "./testFixtures";
import { useCurrentAuthorizations } from "./useCurrentAuthorizations";

beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-18T12:00:00Z")); });
afterEach(() => { cleanup(); vi.useRealTimers(); });

function authorizedProvider() {
  return makeProvider({
    status: "online", online: true, trust_level: "self_signed", mda_verified: false,
    failed_challenges: 3, last_challenge_verified: "2026-09-18T11:00:00Z",
    models: [{ id: "test-model" }], app_attest_authorized: true,
    authorization_expires_at: Date.now() / 1000 + 30,
  });
}

describe("App Attest dashboard authorization", () => {
  it("does not send authorized providers back to legacy MDM verification", () => {
    const provider = authorizedProvider();
    const warnings = computeWarnings(provider, DEFAULT_CTX);
    for (const id of ["trust_self_signed", "untrusted", "challenge_stale", "mda_missing"]) {
      expect(warnings.some((warning) => warning.id === id)).toBe(false);
    }
    expect(routingFor(provider, DEFAULT_CTX)).toBe("routable");
    render(<AttestationPanel provider={{ ...provider, verification: { observed_at: Date.now() / 1000, app_attest: { state: "verified", verified_at: Date.now() / 1000, expires_at: provider.authorization_expires_at }, legacy: { state: "pending" } } }} challengeMaxAgeSeconds={360} />);
    expect(screen.getByText("Verified via App Attest")).toBeInTheDocument();
    expect(screen.queryByText("MDM security posture")).not.toBeInTheDocument();
    expect(screen.queryByText(/Legacy verification alone does not authorize MDM removal/)).not.toBeInTheDocument();
  });

  it("does not present a current legacy badge as MDM removal readiness", () => {
    const now = Date.now() / 1000;
    const provider = makeProvider({ trust_level: "hardware", verification: {
      observed_at: now,
      app_attest: { state: "pending" },
      legacy: { state: "verified", verified_at: now - 1, expires_at: now + 60 },
    } });
    render(<AttestationPanel provider={provider} challengeMaxAgeSeconds={360} />);
    expect(screen.getByText("Verified via legacy authorization")).toBeInTheDocument();
    const guidance = screen.getByText(/Legacy verification alone does not authorize MDM removal/);
    expect(guidance).toHaveTextContent("darkbloom unenroll");
    expect(guidance).toHaveTextContent("current App Attest authorization and coordinator removal readiness");
  });

  it("does not override revocation, offline state, runtime failure or expired/unknown deadlines", () => {
    const provider = authorizedProvider();
    for (const overrides of [
      { status: "untrusted" }, { status: "offline", online: false }, { runtime_verified: false },
      { authorization_expires_at: Date.now() / 1000 }, { authorization_expires_at: undefined },
      { authorization_expires_at: Number.NaN }, { app_attest_authorized: false },
    ]) {
      const invalid = { ...provider, ...overrides };
      expect(hasCurrentAppAttestAuthorization(invalid)).toBe(false);
      expect(routingFor(invalid, DEFAULT_CTX)).not.toBe("routable");
    }
  });

  it("expires cached authorization without another successful fleet poll", () => {
    const providers = [authorizedProvider()];
    const { result } = renderHook(() => useCurrentAuthorizations(providers));
    expect(result.current[0].app_attest_authorized).toBe(true);
    act(() => { vi.advanceTimersByTime(30_001); });
    expect(result.current[0].app_attest_authorized).toBe(false);
    expect(routingFor(result.current[0], DEFAULT_CTX)).toBe("blocked");
  });

  it("uses a renewed deadline and cancels the old expiry timer", () => {
    const provider = authorizedProvider();
    const { result, rerender } = renderHook(({ providers }) => useCurrentAuthorizations(providers), {
      initialProps: { providers: [provider] },
    });
    rerender({ providers: [{ ...provider, authorization_expires_at: Date.now() / 1000 + 60 }] });
    act(() => { vi.advanceTimersByTime(30_001); });
    expect(result.current[0].app_attest_authorized).toBe(true);
    act(() => { vi.advanceTimersByTime(30_000); });
    expect(result.current[0].app_attest_authorized).toBe(false);
  });
});
