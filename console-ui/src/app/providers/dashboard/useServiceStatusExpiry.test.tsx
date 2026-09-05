// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from "vitest";
import { act, render, screen } from "@testing-library/react";
import { baseProvider } from "../../../../__tests__/provider-dashboard-fixtures";
import type { MyProvider } from "../types";
import { useServiceStatusExpiry } from "./useServiceStatusExpiry";
import { deriveRouting } from "./routing";

afterEach(() => vi.useRealTimers());

function Status({ providers }: { providers: MyProvider[] }) {
  useServiceStatusExpiry(providers);
  return <div>{deriveRouting(providers[0], [])}</div>;
}

describe("service status expiry", () => {
  it("expires readiness without receiving another API response", () => {
    vi.useFakeTimers();
    const providers = [baseProvider()];
    render(<Status providers={providers} />);
    expect(screen.getByText("routable")).toBeInTheDocument();
    act(() => vi.advanceTimersByTime(30_001));
    expect(screen.getByText("unknown")).toBeInTheDocument();
    expect(vi.getTimerCount()).toBe(0);
  });
});
