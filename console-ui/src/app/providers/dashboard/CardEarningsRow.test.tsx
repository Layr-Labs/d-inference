// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { CardEarningsRow } from "./CardEarningsRow";
import { makeProvider } from "./testFixtures";

describe("CardEarningsRow", () => {
  it("labels responsiveness as 'Avg TTFT', not 'Avg latency' (DAR-288)", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 842 } })} />);
    expect(screen.getByText("Avg TTFT")).toBeInTheDocument();
    expect(screen.queryByText("Avg latency")).toBeNull();
  });

  it("renders the TTFT value in ms", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 842 } })} />);
    expect(screen.getByText("842ms")).toBeInTheDocument();
  });

  it("rounds the TTFT value", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 842.6 } })} />);
    expect(screen.getByText("843ms")).toBeInTheDocument();
  });

  it("shows an em-dash when TTFT is zero", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 0 } })} />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });

  it("renders the per-box earnings for this machine (DAR-290)", () => {
    render(
      <CardEarningsRow
        provider={makeProvider({ earnings_total_micro_usd: 1_250_000, earnings_count: 7 })}
      />
    );
    expect(screen.getByText("$1.25")).toBeInTheDocument();
    expect(screen.getByText("7 jobs")).toBeInTheDocument();
  });

  it("shows $0.00 / 0 jobs for an offline machine with no resolvable earnings", () => {
    render(
      <CardEarningsRow provider={makeProvider({ earnings_total_micro_usd: 0, earnings_count: 0 })} />
    );
    expect(screen.getByText("$0.00")).toBeInTheDocument();
    expect(screen.getByText("0 jobs")).toBeInTheDocument();
  });
});
