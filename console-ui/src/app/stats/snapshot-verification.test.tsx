import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { currentVerification, summarizeSnapshotVerification, summarizeVerification, type Verification } from "@/lib/verification";
import { ProofDetails } from "@/components/verification/ProofDetails";
import { matchesTrustFilter } from "./provider-fleet";
import { hardwareProvider } from "./hardware/hardware-test-fixtures";

const observed = 1_790_130_685;
function verdict(app: boolean, legacy: boolean): Verification {
  return {
    observed_at: observed,
    app_attest: app ? { state: "verified", verified_at: observed - 10, expires_at: observed + 29 } : { state: "pending" },
    legacy: legacy ? { state: "verified", verified_at: observed - 10, expires_at: observed + 900 } : { state: "pending" },
  };
}
afterEach(() => { cleanup(); vi.useRealTimers(); });

it("does not turn a 336-provider App Attest snapshot into zero after 40 seconds", () => {
  vi.useFakeTimers(); vi.setSystemTime((observed + 40) * 1000);
  const rows = [[270, true, true], [66, true, false], [576, false, true], [227, false, false]] as const;
  const providers = rows.flatMap(([count, app, legacy]) => Array.from({ length: count }, () => ({ verification: verdict(app, legacy) })));
  expect(summarizeSnapshotVerification(providers)).toEqual({ authorized: 912, appAttest: 336, legacy: 846, overlap: 270, total: 1139, known: 1139, unknown: 0 });
  // Snapshot presentation must not extend authorization for live controls.
  expect(summarizeVerification(providers)).toMatchObject({ appAttest: 0, authorized: 846 });
  expect(currentVerification(verdict(true, false))?.app_attest.state).toBe("expired");
  const provider = hardwareProvider({ verification: verdict(true, false) });
  expect(matchesTrustFilter(provider, "app_attest")).toBe(true);
});

it("keeps missing and explicit unknown observations out of snapshot totals", () => {
  const unknown: Verification = { observed_at: observed, app_attest: { state: "unknown" }, legacy: { state: "unknown" } };
  expect(summarizeSnapshotVerification([{}, { verification: unknown }])).toMatchObject({ authorized: 0, known: 0, unknown: 2 });
});

it("labels snapshot proof details as historical rather than current authorization", () => {
  render(<ProofDetails verification={verdict(true, false)} snapshot />);
  expect(screen.getByText(/recorded in this network snapshot/)).toBeInTheDocument();
  expect(screen.queryByText(/Current serving authorization/)).not.toBeInTheDocument();
});
