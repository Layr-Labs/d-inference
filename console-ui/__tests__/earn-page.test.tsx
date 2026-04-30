import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => (
    <div data-testid="topbar">{title}</div>
  ),
}));

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    login: vi.fn(),
  }),
}));

vi.mock("@/lib/google-analytics", () => ({
  trackEvent: vi.fn(),
}));

describe("EarnPage", () => {
  it("keeps rendering when selected hardware has no eligible models", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    fireEvent.click(screen.getByRole("button", { name: "MacBook Air" }));

    expect(screen.getByText("Provider Earnings Calculator")).toBeInTheDocument();
    expect(screen.getByText("No models fit in 32 GB RAM")).toBeInTheDocument();
    expect(screen.getByText("No compatible model for this hardware")).toBeInTheDocument();
  });
});
