import { describe, it, expect } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { ChatInput } from "@/components/ChatInput";
import { WeaverTraceStrip } from "@/components/WeaverTraceStrip";
import { WeaverTraceModal } from "@/components/WeaverTraceModal";
import { TrustBadge } from "@/components/TrustBadge";
import { VerificationModeProvider } from "@/lib/verification-mode";
import { useStore } from "@/lib/store";
import type { WeaverTrace } from "@/lib/api";
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

describe("WeaverTraceStrip", () => {
  it("renders one dynamic diamond per candidate", () => {
    const weaver: WeaverTrace = {
      mode: "deep_plus",
      status: "generating",
      candidateCount: 8,
      verifierCount: 5,
      candidates: Array.from({ length: 8 }, (_, index) => ({
        id: `candidate-${index + 1}`,
        index,
        label: `Agent ${index + 1}`,
        model: "base",
        status: index === 0 ? "streaming" : "queued",
        content: "",
      })),
      verifierScores: [],
    };

    render(<WeaverTraceStrip weaver={weaver} onOpen={() => {}} />);

    expect(screen.getByText("Deep+ · generating")).toBeInTheDocument();
    expect(screen.getAllByLabelText(/Agent \d/)).toHaveLength(8);
  });

  it("renders dynamic agent tabs in the modal", () => {
    const weaver: WeaverTrace = {
      mode: "deep_plus",
      status: "complete",
      candidateCount: 8,
      verifierCount: 5,
      selectedCandidate: "candidate-3",
      confidence: 0.7,
      candidates: Array.from({ length: 8 }, (_, index) => ({
        id: `candidate-${index + 1}`,
        index,
        label: `Agent ${index + 1}`,
        model: "base",
        status: index === 2 ? "selected" : "done",
        content: `answer ${index + 1}`,
      })),
      verifierScores: [],
    };

    render(
      <WeaverTraceModal
        weaver={weaver}
        finalContent="final"
        usage={{ tokenCount: 12 }}
        onClose={() => {}}
        onSelectTab={() => {}}
      />,
    );

    expect(screen.getAllByRole("button", { name: /Agent \d/ })).toHaveLength(8);
    expect(screen.getByRole("button", { name: "Verifiers" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Final" })).toBeInTheDocument();
    expect(screen.getByRole("dialog", { name: "Weaver trace" })).toHaveClass("h-[min(760px,86vh)]");
  });
});

describe("ChatInput", () => {
  it("opens the model selector even when models have not loaded", () => {
    useStore.setState({ models: [], selectedModel: "" });

    render(
      <ChatInput
        onSend={() => {}}
        onStop={() => {}}
        isStreaming={false}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Select model" }));

    expect(screen.getByText("No models loaded")).toBeInTheDocument();
    expect(screen.getByText("Check your API key or coordinator connection.")).toBeInTheDocument();
  });
});
