// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from "vitest";
import { render } from "@testing-library/react";
import type { AuthState } from "./PrivyClientProvider";

// These tests exercise the mock-auth fallback (Privy unconfigured), so the real
// Privy chunk is irrelevant — stub next/dynamic to a no-op component so nothing
// attempts to load it.
vi.mock("next/dynamic", () => ({ default: () => () => null }));

// E2E_AUTH and IS_PRIVY_CONFIGURED are module-level constants read from
// process.env at import time, so each scenario stubs env, resets the module
// registry, and re-imports the provider to re-evaluate them. The captured value
// is whatever AuthContext exposes to children — i.e. MOCK_AUTH.
async function captureMockAuth(
  env: Record<string, string | undefined>,
): Promise<AuthState> {
  vi.resetModules();
  vi.stubEnv("NEXT_PUBLIC_PRIVY_APP_ID", ""); // force the mock-auth fallback
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value ?? "");

  const mod = await import("./PrivyClientProvider");
  let captured: AuthState | null = null;
  function Probe() {
    captured = mod.useAuthContext();
    return null;
  }
  render(
    <mod.PrivyClientProvider>
      <Probe />
    </mod.PrivyClientProvider>,
  );
  if (!captured) throw new Error("auth context was never captured");
  return captured;
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("PrivyClientProvider mock-auth gate", () => {
  // The production-relevant invariant: a build WITHOUT the E2E flag (every real
  // build) must hand out no usable session, even though the mock fallback is
  // authenticated:true (the pre-existing T-020 surface, tracked separately).
  it("is inert without NEXT_PUBLIC_E2E_AUTH: no user and no token", async () => {
    const auth = await captureMockAuth({ NEXT_PUBLIC_E2E_AUTH: undefined });
    expect(auth.user).toBeNull();
    await expect(auth.getAccessToken()).resolves.toBeNull();
  });

  // Any non-"1" value must NOT enable the hook (e.g. a stray "0"/"true").
  it("stays inert when NEXT_PUBLIC_E2E_AUTH is set to a non-\"1\" value", async () => {
    const auth = await captureMockAuth({ NEXT_PUBLIC_E2E_AUTH: "true" });
    expect(auth.user).toBeNull();
    await expect(auth.getAccessToken()).resolves.toBeNull();
  });

  // Only the explicit Playwright opt-in provisions a session, and the token is a
  // deliberately non-bearer-shaped sentinel so a leaked build is obvious.
  it("provisions a sentinel session only when NEXT_PUBLIC_E2E_AUTH=1", async () => {
    const auth = await captureMockAuth({ NEXT_PUBLIC_E2E_AUTH: "1" });
    expect(auth.user).toMatchObject({ id: "e2e-user" });
    const token = await auth.getAccessToken();
    expect(token).toBe("e2e-mock-token-not-for-prod");
    expect(token).not.toMatch(/^(ey|sk-|db-)/); // not a plausible JWT / API key
  });
});
