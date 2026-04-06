import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { TrustBadge } from "@/components/TrustBadge";
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

// ---------------------------------------------------------------------------
// TrustBadge
// ---------------------------------------------------------------------------

describe("TrustBadge", () => {
  it("renders 'Unverified' for trust level none", () => {
    render(<TrustBadge trust={makeTrust({ trustLevel: "none" })} />);
    expect(screen.getByText("Unverified")).toBeInTheDocument();
  });

  it("renders 'Unverified' for non-hardware trust levels", () => {
    render(<TrustBadge trust={makeTrust({ trustLevel: "none" })} />);
    expect(screen.getByText("Unverified")).toBeInTheDocument();
  });

  it("renders 'Hardware Attested' for hardware without MDA", () => {
    render(
      <TrustBadge
        trust={makeTrust({ trustLevel: "hardware", mdaVerified: false })}
      />
    );
    expect(screen.getByText("Hardware Attested")).toBeInTheDocument();
  });

  it("renders 'Apple Attested' for hardware with MDA verified", () => {
    render(
      <TrustBadge
        trust={makeTrust({ trustLevel: "hardware", mdaVerified: true })}
      />
    );
    expect(screen.getByText("Apple Attested")).toBeInTheDocument();
  });

  it("shows SE indicator when secureEnclave is true", () => {
    render(
      <TrustBadge
        trust={makeTrust({ trustLevel: "hardware", secureEnclave: true })}
      />
    );
    expect(screen.getByText((t) => t.includes("SE"))).toBeInTheDocument();
  });

  it("shows MDA indicator when mdaVerified is true", () => {
    render(
      <TrustBadge
        trust={makeTrust({
          trustLevel: "hardware",
          mdaVerified: true,
          secureEnclave: true,
        })}
      />
    );
    expect(screen.getByText((t) => t.includes("MDA"))).toBeInTheDocument();
  });

  // Compact mode -----------------------------------------------------------

  it("in compact mode, does NOT render the label text", () => {
    render(
      <TrustBadge
        trust={makeTrust({ trustLevel: "hardware" })}
        compact
      />
    );
    expect(screen.queryByText("Hardware Attested")).not.toBeInTheDocument();
  });

  it("in compact mode, renders a title attribute with trust details", () => {
    const { container } = render(
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
    expect(span!.getAttribute("title")).toContain("Apple Attested");
    expect(span!.getAttribute("title")).toContain("Secure Enclave");
    expect(span!.getAttribute("title")).toContain("Apple MDA");
  });

  it("in compact mode, does NOT show SE/MDA text spans", () => {
    render(
      <TrustBadge
        trust={makeTrust({
          trustLevel: "hardware",
          secureEnclave: true,
          mdaVerified: true,
        })}
        compact
      />
    );
    // Text spans for SE / MDA are only in non-compact mode
    expect(screen.queryByText((t) => t.includes("SE"))).not.toBeInTheDocument();
    expect(screen.queryByText((t) => t.includes("MDA"))).not.toBeInTheDocument();
  });
});
