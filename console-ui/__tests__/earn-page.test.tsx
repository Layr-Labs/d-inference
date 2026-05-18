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

  it("allows switching to another solo model even when it cannot fit beside the auto-selected model", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    const qwenButton = screen.getByRole("button", { name: /Qwen3.5 27B Claude Opus/ });

    expect(screen.getByText("28 GB weights / 48 GB RAM")).toBeInTheDocument();
    expect(qwenButton).not.toBeDisabled();
    fireEvent.click(qwenButton);

    expect(
      screen.getByText("Selected models share active inference hours, so earnings are not double-counted.")
    ).toBeInTheDocument();
    expect(screen.getByText("27 GB weights / 48 GB RAM")).toBeInTheDocument();

    const gemmaButton = screen.getByRole("button", { name: /Gemma 4 26B/ });
    expect(gemmaButton).not.toBeDisabled();
    fireEvent.click(gemmaButton);

    expect(screen.getByText("28 GB weights / 48 GB RAM")).toBeInTheDocument();
  });
});
