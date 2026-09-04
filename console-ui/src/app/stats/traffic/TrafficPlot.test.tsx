import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { TimeSeriesBucket } from "../types";
import { TrafficPlot } from "./TrafficPlot";

const REQUEST_CHART_NAME = "Requests traffic chart";
const LAST_REQUEST_VALUE = "7 requests";

const data: TimeSeriesBucket[] = [
  { timestamp: "2026-09-04T12:00:00Z", requests: 3, prompt_tokens: 5, completion_tokens: 2, active_providers: 1 },
  { timestamp: "2026-09-04T12:01:00Z", requests: 0, prompt_tokens: 0, completion_tokens: 0, active_providers: 1 },
  { timestamp: "2026-09-04T12:02:00Z", requests: 7, prompt_tokens: 11, completion_tokens: 3, active_providers: 1 },
];

describe("Traffic chart accessibility and layout", () => {
  it("announces every keyboard-selected value in an atomic live region", () => {
    render(<TrafficPlot data={data} metric="requests" view="rate" range="30m" />);
    const plot = screen.getByRole("group", { name: REQUEST_CHART_NAME });
    const readout = screen.getByRole("status");
    expect(readout).toHaveAttribute("aria-live", "polite");
    expect(readout).toHaveAttribute("aria-atomic", "true");
    fireEvent.focus(plot);
    expect(readout).toHaveTextContent(LAST_REQUEST_VALUE);
    fireEvent.keyDown(plot, { key: "ArrowLeft" });
    expect(readout).toHaveTextContent("0 requests");
    fireEvent.keyDown(plot, { key: "Home" });
    expect(readout).toHaveTextContent("3 requests");
    fireEvent.keyDown(plot, { key: "End" });
    expect(readout).toHaveTextContent(LAST_REQUEST_VALUE);
  });

  it("announces cumulative token components with their scope", () => {
    render(<TrafficPlot data={data} metric="tokens" view="cumulative" range="30m" />);
    fireEvent.focus(screen.getByRole("group", { name: "Tokens traffic chart" }));
    const readout = screen.getByRole("status");
    expect(readout).toHaveTextContent("cumulative total");
    expect(readout).toHaveTextContent("21 tokens");
    expect(readout).toHaveTextContent("Input 16");
    expect(readout).toHaveTextContent("Output 5");
  });

  it("keeps axis labels outside the stretched SVG", () => {
    render(<TrafficPlot data={data} metric="requests" view="rate" range="30m" />);
    const plot = screen.getByRole("group", { name: REQUEST_CHART_NAME });
    expect(plot.querySelectorAll("svg text")).toHaveLength(0);
    expect(within(plot).getByText("7").namespaceURI).toBe("http://www.w3.org/1999/xhtml");
    expect(plot.querySelectorAll("svg")).toHaveLength(1);
  });

  it("maps pointer selection to the actual drawing width, excluding the fixed label gutter", () => {
    render(<TrafficPlot data={data} metric="requests" view="rate" range="30m" />);
    const plot = screen.getByRole("group", { name: REQUEST_CHART_NAME });
    const graphic = plot.querySelector("svg")!;
    vi.spyOn(graphic, "getBoundingClientRect").mockReturnValue({ left: 52, right: 292, top: 0, bottom: 200, width: 240, height: 200, x: 52, y: 0, toJSON() {} });
    fireEvent.click(plot, { clientX: 53 });
    expect(screen.getByRole("status")).toHaveTextContent("3 requests");
    fireEvent.click(plot, { clientX: 175 });
    expect(screen.getByRole("status")).toHaveTextContent("0 requests");
    fireEvent.click(plot, { clientX: 290 });
    expect(screen.getByRole("status")).toHaveTextContent(LAST_REQUEST_VALUE);
  });
});
