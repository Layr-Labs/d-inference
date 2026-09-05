// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { CardEarningsRow } from "./CardEarningsRow";
import { makeProvider } from "./testFixtures";

describe("CardEarningsRow", () => {
  it("labels prefill-adjusted responsiveness accurately", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 842 } })} />);
    expect(screen.getByText("Adjusted latency")).toBeInTheDocument();
    expect(screen.queryByText("Avg latency")).toBeNull();
  });

  it("renders the adjusted latency value in ms", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 842 } })} />);
    expect(screen.getByText("842ms")).toBeInTheDocument();
  });

  it("rounds the adjusted latency value", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 842.6 } })} />);
    expect(screen.getByText("843ms")).toBeInTheDocument();
  });

  it("shows an em-dash when adjusted latency is zero", () => {
    render(<CardEarningsRow provider={makeProvider({ reputation: { avg_response_time_ms: 0 } })} />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });

  it("keeps the operational per-box stats (Reputation, Tokens, Adjusted latency)", () => {
    render(<CardEarningsRow provider={makeProvider()} />);
    expect(screen.getByText("Legacy reputation")).toBeInTheDocument();
    expect(screen.getByText("Tokens")).toBeInTheDocument();
    expect(screen.getByText("Adjusted latency")).toBeInTheDocument();
  });

  it("no longer shows a per-machine earnings stat (earnings live in the fleet header)", () => {
    render(<CardEarningsRow provider={makeProvider()} />);
    expect(screen.queryByText("Earnings")).toBeNull();
  });
});
