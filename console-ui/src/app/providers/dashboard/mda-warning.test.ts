import { describe, it, expect } from "vitest";
import { computeWarnings } from "../warnings";
import { deriveRouting } from "./routing";
import { resolveFix } from "./fixes";
import { makeProvider } from "./testFixtures";

const ctx = {
  latest_provider_version: "0.6.5",
  min_provider_version: "0.6.0",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

describe("Apple Device Attestation (mda_missing) warning", () => {
  it("is informational, NOT degrading — MDA is not a routing factor", () => {
    const p = makeProvider({ status: "serving", online: true, mda_verified: false });
    const mda = computeWarnings(p, ctx).find((w) => w.id === "mda_missing");

    expect(mda).toBeTruthy();
    expect(mda!.severity).toBe("info"); // not "degrading"
    expect(mda!.title).not.toMatch(/incomplete/i);
  });

  it("toggling mda_verified does not change routing — same state with and without it", () => {
    const withMda = makeProvider({ status: "serving", online: true, mda_verified: true });
    const withoutMda = makeProvider({ status: "serving", online: true, mda_verified: false });
    const r1 = deriveRouting(withMda, computeWarnings(withMda, ctx));
    const r2 = deriveRouting(withoutMda, computeWarnings(withoutMda, ctx));
    expect(r2).toBe(r1); // MDA presence/absence must not alter the earning state
  });

  it("offers no action CTA — MDA is earned automatically and reused across restarts", () => {
    const fix = resolveFix("mda_missing");
    expect(fix.kind).toBe("guidance");
    expect(fix.command).toBeUndefined();
    expect(fix.href).toBeUndefined();
  });

  it("is absent once MDA is verified", () => {
    const p = makeProvider({ status: "serving", online: true, mda_verified: true });
    expect(computeWarnings(p, ctx).some((w) => w.id === "mda_missing")).toBe(false);
  });
});
