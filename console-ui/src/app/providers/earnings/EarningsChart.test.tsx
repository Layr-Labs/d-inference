// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { EarningsChart } from "./EarningsChart";
import type { DayBucket } from "./aggregate";

// Geometry constants mirrored from EarningsChart: W=640, PAD_X=40, PAD_Y=16,
// H=220, LABEL_H=22 -> chart height 182, baseline y = 198.
const DAYS: DayBucket[] = [
  { day: "2025-05-01", micro: 100_000 }, // peak -> y = 16
  { day: "2025-05-02", micro: 0 }, //         -> y = 198 (baseline)
  { day: "2025-05-03", micro: 50_000 }, //    -> y = 107
];

describe("EarningsChart", () => {
  it("shows the placeholder until there are two days of history", () => {
    render(<EarningsChart days={DAYS.slice(0, 1)} />);
    expect(screen.getByText(/Not enough history yet/)).toBeInTheDocument();
    expect(document.querySelector("svg")).toBeNull();
  });

  it("plots one point per day and closes the area at the baseline", () => {
    const { container } = render(<EarningsChart days={DAYS} />);
    expect(container.querySelector("polyline")?.getAttribute("points")).toBe(
      "40,16 320,198 600,107",
    );
    // Area path: down-left corner, the trend points, down-right corner, close.
    expect(container.querySelector("path")?.getAttribute("d")).toBe(
      "M40,198 L40,16 L320,198 L600,107 L600,198 Z",
    );
  });

  it("labels the first and last day on the x axis", () => {
    render(<EarningsChart days={DAYS} />);
    expect(screen.getByText("May 1")).toBeInTheDocument();
    expect(screen.getByText("May 3")).toBeInTheDocument();
  });
});
