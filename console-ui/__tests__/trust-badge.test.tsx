import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { TrustBadge } from "@/components/TrustBadge";
import type { TrustMetadata } from "@/lib/api";
import type { Verification, VerificationState } from "@/lib/verification";

// TrustBadge renders only the coordinator's dispatch-time verification
// snapshot (`trust.verification`). The legacy per-response trust fields are
// maxed out on purpose: none of them may turn into an authorization claim.
const legacyAllTrue: TrustMetadata = {
  attested: true,
  trustLevel: "hardware",
  secureEnclave: true,
  mdaVerified: true,
  providerChip: "Apple M4 Max",
  providerModel: "Mac16,5",
};

const observedAt = 1_790_000_000;
const snapshot = (state: VerificationState): Verification => ({
  observed_at: observedAt,
  app_attest: { state, verified_at: observedAt - 10, expires_at: observedAt + 30 },
  legacy: { state: "pending" },
});

describe("TrustBadge", () => {
  it("does not infer authorization from legacy trust fields without a verification snapshot", () => {
    render(<TrustBadge trust={legacyAllTrue} />);
    expect(screen.getByText("Verification unavailable")).toBeInTheDocument();
  });

  it("shows the snapshot's non-verified state even when legacy fields claim hardware trust", () => {
    render(<TrustBadge trust={{ ...legacyAllTrue, verification: snapshot("revoked") }} />);
    expect(screen.getByText("Verification revoked")).toBeInTheDocument();
    expect(screen.queryByText(/^Verified via/)).not.toBeInTheDocument();
  });

  it("in compact mode carries the verdict only in the title", () => {
    const { container } = render(
      <TrustBadge trust={{ ...legacyAllTrue, verification: snapshot("verified") }} compact />,
    );
    expect(container.querySelector("span[title]")?.getAttribute("title")).toBe(
      "Verified via App Attest at dispatch",
    );
    expect(screen.queryByText("Verified via App Attest")).not.toBeInTheDocument();
  });
});
