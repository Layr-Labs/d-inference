// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { CardRoutingVerdict } from "./CardRoutingVerdict";
import { baseProvider, serviceStatus } from "../../../../__tests__/provider-dashboard-fixtures";
import { deriveRouting } from "./routing";

afterEach(() => vi.useRealTimers());

describe("coordinator routing explanation", () => {
  it("distinguishes ready from active traffic", () => {
    const provider = baseProvider();
    render(<CardRoutingVerdict provider={provider} state={deriveRouting(provider, [])} topWarning={null} />);
    expect(screen.getByText("Ready for public work")).toBeInTheDocument();
    expect(screen.getByText(/No requests currently in progress/)).toBeInTheDocument();
    expect(screen.queryByText(/EARNING|full routing priority|priority: normal/i)).toBeNull();
  });
  it("shows current pending work independently of eligibility restrictions", () => {
    const provider = baseProvider({service_status: serviceStatus({state: "limited", pending_requests: 2, reason: "error_cooldown"})});
    render(<CardRoutingVerdict provider={provider} state={deriveRouting(provider, [])} topWarning={null} />);
    expect(screen.getByText(/2 requests in progress/)).toBeInTheDocument();
    expect(screen.getByText("Recent failures temporarily restrict this workload")).toBeInTheDocument();
  });
  it("expires a previously ready snapshot instead of keeping an all-clear", () => {
    vi.useFakeTimers();
    const provider = baseProvider();
    const {rerender} = render(<CardRoutingVerdict provider={provider} state={deriveRouting(provider, [])} topWarning={null} />);
    vi.advanceTimersByTime(31_000);
    rerender(<CardRoutingVerdict provider={provider} state={deriveRouting(provider, [])} topWarning={null} />);
    expect(screen.getByText("Coordinator status unavailable")).toBeInTheDocument();
    expect(screen.queryByText("Ready for public work")).toBeNull();
  });
  it("presents a normal routing probe with an explicit request scope", () => {
    const provider = baseProvider();
    render(<CardRoutingVerdict provider={provider} state={deriveRouting(provider, [])} topWarning={null} />);
    expect(screen.getByText(/500 input \/ 256 output tokens/)).toBeInTheDocument();
    expect(screen.getByText(/does not reserve capacity or guarantee traffic/)).toBeInTheDocument();
  });
});
