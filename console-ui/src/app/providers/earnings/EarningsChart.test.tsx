// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { EarningsChart } from "./EarningsChart";
import type { DayBucket } from "./aggregate";

// Geometry constants mirrored from EarningsChart: W=640, PAD_X=40, PAD_Y=16,
// H=220, LABEL_H=22 -> chart height 182, baseline y = 198.
const DAYS: DayBucket[] = [
  { day: "2025-05-01", micro: 100_000, jobs: 4 }, // peak -> y = 16
  { day: "2025-05-02", micro: 0, jobs: 0 }, //         -> y = 198 (baseline)
  { day: "2025-05-03", micro: 50_000, jobs: 2 }, //    -> y = 107
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

  it("plots the demand series scaled to its own peak", () => {
    const { container } = render(<EarningsChart days={DAYS} />);
    // jobs 4/0/2 against peak 4 -> y = 16, 198, 107 (same shape as earnings here).
    expect(
      container
        .querySelector('[data-testid="demand-line"]')
        ?.getAttribute("points"),
    ).toBe("40,16 320,198 600,107");
    expect(screen.getByText("Demand (jobs)")).toBeInTheDocument();
  });

  it("labels the first and last day on the x axis", () => {
    render(<EarningsChart days={DAYS} />);
    expect(screen.getByText("May 1")).toBeInTheDocument();
    expect(screen.getByText("May 3")).toBeInTheDocument();
  });

  it("scales huge demand independently with compact right-axis ticks", () => {
    const { container } = render(
      <EarningsChart
        days={[
          { day: "2025-05-01", micro: 100_000, jobs: 48_860 },
          { day: "2025-05-02", micro: 50_000, jobs: 24_430 },
        ]}
      />,
    );
    // Peak tick is compacted, and both series still span the full chart
    // height (peak of each -> y = 16) despite a ~500x magnitude gap.
    expect(screen.getByText("48.9k")).toBeInTheDocument();
    expect(
      container.querySelector('[data-testid="demand-line"]')?.getAttribute("points"),
    ).toBe("40,16 600,107");
    expect(container.querySelector("polyline")?.getAttribute("points")).toBe(
      "40,16 600,107",
    );
  });

  it("shows day, earnings, and jobs in a tooltip on hover", () => {
    const { container } = render(<EarningsChart days={DAYS} />);
    const svg = container.querySelector("svg")!;
    // jsdom has no layout; give the svg a rendered size matching the viewBox.
    vi.spyOn(svg, "getBoundingClientRect").mockReturnValue({
      left: 0, top: 0, width: 640, height: 220, right: 640, bottom: 220, x: 0, y: 0,
      toJSON: () => ({}),
    } as DOMRect);

    fireEvent.mouseMove(svg, { clientX: 610, clientY: 100 });
    const tooltip = screen.getByTestId("chart-tooltip");
    expect(tooltip).toHaveTextContent("May 3");
    expect(tooltip).toHaveTextContent("$0.05 earned");
    expect(tooltip).toHaveTextContent("2 jobs");
    expect(screen.getByTestId("hover-marker")).toBeInTheDocument();

    fireEvent.mouseLeave(svg);
    expect(screen.queryByTestId("chart-tooltip")).toBeNull();
    expect(screen.queryByTestId("hover-marker")).toBeNull();
  });
});
