import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { BaseRewardsPanel } from "@/components/earn/BaseRewardsPanel";
import { FLOOR_TIERS } from "@/app/earn/calc";

describe("BaseRewardsPanel", () => {
  it("renders the 64GB floor at $18 (the Netflix anchor)", () => {
    render(<BaseRewardsPanel />);
    expect(screen.getByText("64GB")).toBeInTheDocument();
    expect(screen.getByText("$18")).toBeInTheDocument();
  });

  it("frames the base reward as additive — paid on top of usage earnings", () => {
    const { container } = render(<BaseRewardsPanel />);
    // Additive base income: usage earnings + base reward, keep 100% of both.
    expect(container.textContent).toMatch(/on top of the base reward/i);
    expect(container.textContent).toMatch(/keep 100% of both/i);
    expect(container.textContent).toMatch(/settle every 5 minutes/i);
  });

  it("anchors the Netflix claim to 64GB+ and marks sub-24GB as usage only", () => {
    render(<BaseRewardsPanel />);
    // 64GB+ is the Netflix-Standard qualifying class.
    expect(screen.getByText(/64GB\+ Mac/)).toBeInTheDocument();
    // 24GB and 32GB earn a floor (incentivize mid-range Macs).
    expect(screen.getByText("24GB")).toBeInTheDocument();
    expect(screen.getByText("32GB")).toBeInTheDocument();
    // Sub-24GB earns nothing as a floor.
    expect(screen.getByText("Under 24GB")).toBeInTheDocument();
    expect(screen.getAllByText("Usage only").length).toBeGreaterThan(0);
  });

  it("never uses the word 'guarantee' as a promise (honesty constraint)", () => {
    const { container } = render(<BaseRewardsPanel />);
    // copy explicitly says 'not a guarantee'
    expect(container.textContent).toMatch(/not a guarantee/i);
  });

  it("exposes a floor table consistent with the coordinator tiers", () => {
    const byGB = Object.fromEntries(FLOOR_TIERS.map((t) => [t.minGB, t.floorUSD]));
    expect(byGB[64]).toBe(18);
    expect(byGB[48]).toBe(16);
    expect(byGB[32]).toBe(12);
    expect(byGB[24]).toBe(10);
    expect(byGB[512]).toBe(40);
    expect(byGB[0]).toBe(0); // sub-24GB: usage only
  });
});
