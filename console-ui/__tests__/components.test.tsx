import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { TrustBadge } from "@/components/TrustBadge";
import { VerificationModeProvider } from "@/lib/verification-mode";
import type { TrustMetadata } from "@/lib/api";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTrust(overrides: Partial<TrustMetadata> = {}): TrustMetadata {
  return {
    attested: false,
    trustLevel: "none",
    secureEnclave: false,
    mdaVerified: false,
    providerChip: "",
    providerSerial: "",
    providerModel: "",
    ...overrides,
  };
}

/** Render wrapped in VerificationModeProvider (default: normal mode). */
function renderWithMode(ui: React.ReactElement) {
  return render(<VerificationModeProvider>{ui}</VerificationModeProvider>);
}

// ---------------------------------------------------------------------------
// TrustBadge — Normal Mode (default)
// ---------------------------------------------------------------------------

describe("TrustBadge (normal mode)", () => {
  it("renders 'Unverified' for trust level none", () => {
    renderWithMode(<TrustBadge trust={makeTrust({ trustLevel: "none" })} />);
    expect(screen.getByText("Unverified")).toBeInTheDocument();
  });

  it("renders 'Hardware Verified' for hardware without MDA", () => {
    renderWithMode(
      <TrustBadge
        trust={makeTrust({ trustLevel: "hardware", mdaVerified: false })}
      />
    );
    expect(screen.getByText("Hardware Verified")).toBeInTheDocument();
  });

  it("renders 'Apple-verified hardware' for hardware with MDA", () => {
    renderWithMode(
      <TrustBadge
        trust={makeTrust({ trustLevel: "hardware", mdaVerified: true })}
      />
    );
    expect(screen.getByText("Apple-verified hardware")).toBeInTheDocument();
  });

  it("does NOT show SE/MDA indicators in normal mode", () => {
    renderWithMode(
      <TrustBadge
        trust={makeTrust({
          trustLevel: "hardware",
          secureEnclave: true,
          mdaVerified: true,
        })}
      />
    );
    expect(screen.queryByText((t) => t.includes("SE"))).not.toBeInTheDocument();
    expect(screen.queryByText((t) => t.includes("MDA"))).not.toBeInTheDocument();
  });

  // Compact mode -----------------------------------------------------------

  it("in compact mode, does NOT render the label text", () => {
    renderWithMode(
      <TrustBadge trust={makeTrust({ trustLevel: "hardware" })} compact />
    );
    expect(screen.queryByText("Hardware Verified")).not.toBeInTheDocument();
  });

  it("in compact mode, renders a title attribute", () => {
    const { container } = renderWithMode(
      <TrustBadge
        trust={makeTrust({
          trustLevel: "hardware",
          secureEnclave: true,
          mdaVerified: true,
        })}
        compact
      />
    );
    const span = container.querySelector("span[title]");
    expect(span).toBeTruthy();
    expect(span!.getAttribute("title")).toBe("Apple-verified hardware");
  });
});
