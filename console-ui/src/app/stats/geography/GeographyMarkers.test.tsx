import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GeographyMarkers, GeographyTooltip } from "./GeographyMarkers";
import type { MarkerCluster } from "@/components/stats/network-map";

const cluster: MarkerCluster = {
  key: "reykjavik", xPct: 44, yPct: 5, totalNodes: 10, isCluster: false,
  members: [{ key: "reykjavik", xPct: 44, yPct: 5, nodes: 10, label: "Reykjavik, Iceland", detail: "10 requests" }],
};

describe("geography markers", () => {
  it("renders top-edge tooltips below the marker and outside the clipped map", () => {
    const { container } = render(<GeographyTooltip id="tip" cluster={cluster} mode="requests" anchor={{ x: 3, top: 50, bottom: 85 }} />);
    const tooltip = screen.getByRole("tooltip");
    expect(tooltip.parentElement).toBe(document.body);
    expect(container).not.toContainElement(tooltip);
    expect(tooltip).toHaveStyle({ top: "97px", left: "12px" });
    expect(tooltip).toHaveTextContent("10 requests");
  });

  it("shows location detail to keyboard users and dismisses it with Escape", () => {
    render(<GeographyMarkers markers={cluster.members} mode="requests" context={{ width: 1000, height: 500, scale: 1, zoomToPercent: vi.fn() }} onExplore={vi.fn()} />);
    const marker = screen.getByRole("button", { name: "Reykjavik, Iceland: 10 requests" });
    fireEvent.focus(marker);
    expect(screen.getByRole("tooltip")).toHaveTextContent("Reykjavik, Iceland");
    fireEvent.keyDown(marker, { key: "Escape" });
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });
});
