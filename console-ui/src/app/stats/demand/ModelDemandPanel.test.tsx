import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { demandCSV } from "./history";
import { ModelDemandPanel } from "./ModelDemandPanel";
import { isModelDemandResponse, type ModelDemandResponse } from "./types";

const historyModelLabel = "Model for demand history";
const snapshot: ModelDemandResponse = {
  bucket_seconds: 3600, window: "24h", start_at: "2026-09-19T10:00:00Z", end_at: "2026-09-20T10:00:00Z", updated_at: "2026-09-20T11:00:00Z",
  collection_started_at: "2026-09-19T12:00:00Z", coverage: "recorded_requests_only",
  models: [
    { model: "model-a", time_series: [], requests: 100, completed: 90, capacity_rejected: 5, latency_rejected: 1, timed_out: 1, failed: 1, cancelled: 1, unknown: 1, http_429: 7 },
    { model: "model-b", time_series: [], requests: 30, completed: 5, capacity_rejected: 20, latency_rejected: 0, timed_out: 0, failed: 0, cancelled: 0, unknown: 5, http_429: 20 },
  ],
};
for (const model of snapshot.models) {
  model.time_series = Array.from({ length: 24 }, (_, index) => ({ timestamp: new Date(Date.parse(snapshot.start_at) + index * 3600000).toISOString(), counts: index === 0 ? { ...model } : null }));
}
afterEach(() => vi.unstubAllGlobals());
function mockResponse(value = snapshot) { return Response.json(value); }
function renderPanel() { render(<ModelDemandPanel refreshToken={null} catalogData={null} />); }

describe("Model demand", () => {
  it("shows shared-scale request bars, sorting, and reconciled details", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(mockResponse()));
    renderPanel();
    await screen.findByRole("button", { name: "Show demand details for model-a" });
    expect(screen.getByText(/This window has only partial history/)).toBeInTheDocument();
    expect(screen.getAllByRole("img").some(n => n.getAttribute("aria-label")?.includes("shared scale to 100 requests"))).toBe(true);
    fireEvent.change(screen.getByRole("combobox", { name: "Sort model demand" }), { target: { value: "capacity" } });
    expect(screen.getAllByRole("button", { name: /Show demand details/ })[0]).toHaveAccessibleName("Show demand details for model-b");
    fireEvent.click(screen.getByRole("button", { name: "Show demand details for model-a" }));
    const details = screen.getByRole("region", { name: "model-a demand details" });
    expect(within(details).getByText("Timed out")).toBeInTheDocument();
    expect(within(details).getByText(/HTTP 429 responses: 7/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Hide demand details for model-a" })).toHaveAttribute("aria-expanded", "true");
  });
  it("changes range, hides stale data on errors, and retries", async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(mockResponse()).mockResolvedValueOnce(new Response(null, { status: 503 })).mockResolvedValueOnce(mockResponse({ ...snapshot, window: "7d", bucket_seconds: 21600, start_at: "2026-09-13T10:00:00Z", models: snapshot.models.map(m => ({ ...m, time_series: Array.from({length:28},(_,i)=>({timestamp:new Date(Date.parse("2026-09-13T10:00:00Z")+i*21600000).toISOString(),counts:null})) })) }));
    vi.stubGlobal("fetch", fetcher); renderPanel();
    await screen.findByRole("button", { name: /Show demand details for model-a/ });
    fireEvent.change(screen.getByRole("combobox", { name: historyModelLabel }), { target: { value: "model-b" } });
    fireEvent.click(screen.getByRole("button", { name: "7 days" }));
    await screen.findByRole("alert");
    expect(screen.queryByRole("button", { name: /Show demand details for model-a/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry model demand" }));
    await screen.findByRole("button", { name: /Show demand details for model-a/ });
    expect(screen.getByRole("combobox", { name: historyModelLabel })).toHaveValue("model-b");
    expect(fetcher).toHaveBeenLastCalledWith("/api/network/model-demand?window=7d", expect.any(Object));
  });
  it("explains suppression without claiming zero demand", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(mockResponse({ ...snapshot, models: [] }))); renderPanel();
    expect(await screen.findByText(/this does not mean no requests were received/)).toBeInTheDocument();
  });
  it("offers metric charts, exact intervals, and keyboard inspection without zero-filling gaps", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(mockResponse())); renderPanel();
    const plot = await screen.findByRole("group", { name: "model-a demand history chart" });
    fireEvent.focus(plot);
    expect(screen.getByText("100 received")).toBeInTheDocument();
    fireEvent.keyDown(plot, { key: "ArrowRight" });
    expect(screen.getByText(/This is not a measured zero/)).toBeInTheDocument();
    fireEvent.change(screen.getByRole("combobox", { name: "Demand history metric" }), { target: { value: "capacity_rejected" } });
    expect(screen.getByRole("combobox", { name: "Demand history metric" })).toHaveValue("capacity_rejected");
    fireEvent.change(screen.getByRole("combobox", { name: historyModelLabel }), { target: { value: "model-b" } });
    expect(screen.getByRole("group", { name: "model-b demand history chart" })).toBeInTheDocument();
    fireEvent.click(screen.getByText("View interval data"));
    expect(screen.getByRole("table", { name: "model-b request outcomes by interval" })).toBeVisible();
  });
  it("preserves the selected chart when the Stats snapshot refreshes", async () => {
    const fetcher = vi.fn().mockImplementation(async () => mockResponse());
    vi.stubGlobal("fetch", fetcher);
    const { rerender } = render(<ModelDemandPanel refreshToken="first" catalogData={null} />);
    await screen.findByRole("combobox", { name: historyModelLabel });
    fireEvent.change(screen.getByRole("combobox", { name: historyModelLabel }), { target: { value: "model-b" } });
    rerender(<ModelDemandPanel refreshToken="second" catalogData={null} />);
    await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
    expect(screen.getByRole("combobox", { name: historyModelLabel })).toHaveValue("model-b");
  });
  it("exports unpublished intervals with blank values, not zeros", () => {
    const rows = demandCSV(snapshot.models[0], 3600).split("\n");
    expect(rows).toHaveLength(25);
    expect(rows[1]).toContain(",true,100,90,5,");
    expect(rows[2]).toMatch(/,false,,,,,,,,,$/);
  });
  it("refuses nonreconciling totals and malformed timestamps", () => {
    expect(isModelDemandResponse(snapshot, "24h")).toBe(true);
    expect(isModelDemandResponse({ ...snapshot, end_at: "bad" }, "24h")).toBe(false);
    expect(isModelDemandResponse({ ...snapshot, models: [{ ...snapshot.models[0], requests: 101 }] }, "24h")).toBe(false);
    expect(isModelDemandResponse({ ...snapshot, models: [snapshot.models[0], snapshot.models[0]] }, "24h")).toBe(false);
    expect(isModelDemandResponse(snapshot, "7d")).toBe(false);
  });
});
