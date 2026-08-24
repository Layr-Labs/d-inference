import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { BaseRewardsPanel } from "@/components/earn/BaseRewardsPanel";
import type { EarningsMarketBaseRewards } from "@/lib/api";

const policy: EarningsMarketBaseRewards = {
  enabled: true,
  monthly_pool_micro_usd: 9_000_000_000,
  min_uptime_fraction: 0.9,
  tiers: [
    { min_ram_gb: 64, monthly_micro_usd: 18_000_000 },
    { min_ram_gb: 48, monthly_micro_usd: 16_000_000 },
    { min_ram_gb: 24, monthly_micro_usd: 10_000_000 },
  ],
};

describe("BaseRewardsPanel", () => {
  it("is a collapsed accordion by default", () => {
    const { container } = render(<BaseRewardsPanel policy={policy} state="ready" />);
    expect(container.querySelector("details")?.open).toBe(false);
  });

  it("renders the coordinator-supplied tier and pool policy", () => {
    render(<BaseRewardsPanel policy={policy} state="ready" />);
    expect(screen.getByText("64GB+")).toBeInTheDocument();
    expect(screen.getByText("$18")).toBeInTheDocument();
    expect(screen.getByText("$216")).toBeInTheDocument();
    expect(screen.getByText("Under 24GB")).toBeInTheDocument();
    expect(screen.getAllByText("—")).toHaveLength(2);
    expect(screen.getByText(/fixed \$9,000\.00 monthly pool/)).toBeInTheDocument();
  });

  it("labels tiers as capped maxima, never guaranteed payouts", () => {
    const { container } = render(<BaseRewardsPanel policy={policy} state="ready" />);
    expect(container.textContent).toMatch(/maximum monthly tier/i);
    expect(container.textContent).toMatch(/not guaranteed/i);
    expect(container.textContent).toMatch(/subject to eligibility and the fleet-wide pool cap/i);
  });

  it("shows an explicit unavailable state without static fallback tiers", () => {
    render(<BaseRewardsPanel policy={null} state="unavailable" />);
    expect(screen.getByText("Reward policy unavailable.")).toBeInTheDocument();
    expect(screen.queryByText("64GB+")).not.toBeInTheDocument();
  });
});
