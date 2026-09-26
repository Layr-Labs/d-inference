import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { demandCSV } from "./history";
import { ModelDemandPanel } from "./ModelDemandPanel";
import { isModelDemandResponse, type DemandCounts, type DemandWindow, type ModelDemandResponse } from "./types";

const historyModelLabel = "Model for demand history";
const snapshot: ModelDemandResponse = {
  bucket_seconds: 3600, window: "24h", start_at: "2026-09-19T10:00:00Z", end_at: "2026-09-20T10:00:00Z", updated_at: "2026-09-20T11:00:00Z",
  collection_started_at: "2026-09-19T12:00:00Z", coverage: "published_hourly_cohorts",
  models: [
    { model: "model-a", time_series: [], requests: 100, completed: 90, capacity_rejected: 5, latency_rejected: 1, timed_out: 1, failed: 1, cancelled: 1, unknown: 1, http_429: 7 },
    { model: "model-b", time_series: [], requests: 30, completed: 5, capacity_rejected: 20, latency_rejected: 0, timed_out: 0, failed: 0, cancelled: 0, unknown: 5, http_429: 20 },
  ],
};
for (const model of snapshot.models) {
  model.time_series = Array.from({ length: 24 }, (_, index) => ({ timestamp: new Date(Date.parse(snapshot.start_at) + index * 3600000).toISOString(), counts: index === 0 ? { ...model } : null }));
}
function snapshotForWindow(window: DemandWindow): ModelDemandResponse {
  const bucketSeconds = window === "24h" ? 3600 : window === "7d" ? 21600 : 86400;
  const length = window === "24h" ? 24 : window === "7d" ? 28 : 30;
  const start = Date.parse(snapshot.end_at) - bucketSeconds * length * 1000;
  return {
    ...snapshot, window, bucket_seconds: bucketSeconds, start_at: new Date(start).toISOString(),
    models: snapshot.models.map(model => ({
      ...model,
      time_series: Array.from({ length }, (_, index) => ({ timestamp: new Date(start + index * bucketSeconds * 1000).toISOString(), counts: index === 0 ? { ...model.time_series[0].counts! } : null })),
    })),
  };
}
afterEach(() => vi.unstubAllGlobals());
function mockResponse(value = snapshot) { return Response.json(value); }
function renderPanel() { render(<ModelDemandPanel refreshToken={null} catalogData={null} />); }

describe("Model demand", () => {
  it("sorts models by capacity and expands their outcome details", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(mockResponse()));
    renderPanel();
    await screen.findByRole("button", { name: "Show demand details for model-a" });
    fireEvent.change(screen.getByRole("combobox", { name: "Sort model demand" }), { target: { value: "capacity" } });
    expect(screen.getAllByRole("button", { name: /Show demand details/ })[0]).toHaveAccessibleName("Show demand details for model-b");
    fireEvent.click(screen.getByRole("button", { name: "Show demand details for model-a" }));
    expect(screen.getByRole("region", { name: "model-a demand details" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Hide demand details for model-a" })).toHaveAttribute("aria-expanded", "true");
  });
  it("changes range, hides stale data on errors, and retries", async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(mockResponse()).mockResolvedValueOnce(new Response(null, { status: 503 })).mockResolvedValueOnce(mockResponse(snapshotForWindow("7d")));
    vi.stubGlobal("fetch", fetcher); renderPanel();
    await screen.findByRole("button", { name: /Show demand details for model-a/ });
    fireEvent.change(screen.getByRole("combobox", { name: historyModelLabel }), { target: { value: "model-b" } });
    fireEvent.change(screen.getByRole("combobox", { name: "Demand history metric" }), { target: { value: "completion_rate" } });
    fireEvent.click(screen.getByRole("button", { name: "7 days" }));
    await screen.findByRole("alert");
    expect(screen.queryByRole("button", { name: /Show demand details for model-a/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry model demand" }));
    await screen.findByRole("button", { name: /Show demand details for model-a/ });
    expect(screen.getByRole("combobox", { name: historyModelLabel })).toHaveValue("model-b");
    expect(screen.getByRole("combobox", { name: "Demand history metric" })).toHaveValue("completion_rate");
    expect(screen.getByRole("button", { name: "7 days" })).toHaveAttribute("aria-pressed", "true");
  });
  it("offers metric charts and interval data without zero-filling gaps", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(mockResponse())); renderPanel();
    await screen.findByRole("group", { name: "model-a published demand history chart" });
    fireEvent.change(screen.getByRole("combobox", { name: "Demand history metric" }), { target: { value: "capacity_rejected" } });
    expect(screen.getByRole("combobox", { name: "Demand history metric" })).toHaveValue("capacity_rejected");
    fireEvent.change(screen.getByRole("combobox", { name: historyModelLabel }), { target: { value: "model-b" } });
    expect(screen.getByRole("group", { name: "model-b published demand history chart" })).toBeInTheDocument();
    fireEvent.click(screen.getByText("View published interval data"));
    const table = screen.getByRole("table", { name: "model-b published request outcomes by interval" });
    expect(table).toBeVisible();
    const rows = within(table).getAllByRole("row");
    expect(within(rows[1]).getAllByRole("cell").map(cell => cell.textContent)).toEqual(["30", "5", "20", "0", "0", "0", "0", "5", "20"]);
    const gap = within(rows[2]).getAllByRole("cell");
    expect(gap).toHaveLength(1);
    expect(gap[0]).toHaveAttribute("colspan", "9");
    expect(gap[0]).not.toHaveTextContent(/\d/);
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
    const header = rows[0].split(",");
    const published = Object.fromEntries(rows[1].split(",").map((value, index) => [header[index], value]));
    const gap = Object.fromEntries(rows[2].split(",").map((value, index) => [header[index], value]));
    expect(published).toEqual({ interval_start_utc: "2026-09-19T10:00:00.000Z", interval_end_utc: "2026-09-19T11:00:00.000Z", has_published_hourly_cohorts: "true", published_requests: "100", published_completed: "90", published_capacity_rejected: "5", published_latency_rejected: "1", published_timed_out: "1", published_failed: "1", published_cancelled: "1", published_unknown: "1", published_http_429: "7" });
    expect(gap.has_published_hourly_cohorts).toBe("false");
    expect(header.slice(3).map(field => gap[field])).toEqual(Array(9).fill(""));
  });
  it.each(["legacy coverage", "hidden residual"])("hides a refreshed %s response and recovers on retry", async kind => {
    const unsafe = structuredClone(snapshot);
    if (kind === "hidden residual") {
      unsafe.models[0].requests += 19;
      unsafe.models[0].capacity_rejected += 19;
    }
    const invalid = kind === "legacy coverage" ? { ...unsafe, coverage: "recorded_requests_only" } : unsafe;
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(mockResponse()).mockResolvedValueOnce(Response.json(invalid)).mockResolvedValueOnce(mockResponse()));
    const { rerender } = render(<ModelDemandPanel refreshToken="first" catalogData={null} />);
    await screen.findByRole("combobox", { name: historyModelLabel });
    fireEvent.change(screen.getByRole("combobox", { name: historyModelLabel }), { target: { value: "model-b" } });
    rerender(<ModelDemandPanel refreshToken="second" catalogData={null} />);
    await screen.findByRole("alert");
    expect(screen.queryByRole("button", { name: /Show demand details/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Download/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry model demand" }));
    await screen.findByRole("combobox", { name: historyModelLabel });
    expect(screen.getByRole("combobox", { name: historyModelLabel })).toHaveValue("model-b");
  });
  it.each<DemandWindow>(["24h", "7d", "30d"])("accepts summed published cohorts and rejects hidden residuals for %s", window => {
    const value = snapshotForWindow(window);
    const model = value.models[0];
    model.time_series[2].counts = { ...model.time_series[0].counts! };
    for (const field of ["requests", "completed", "capacity_rejected", "timed_out", "latency_rejected", "failed", "cancelled", "unknown", "http_429"] as const) {
      model[field] *= 2;
    }
    expect(isModelDemandResponse(value, window)).toBe(true);
    model.requests += 19;
    model.capacity_rejected += 19;
    expect(isModelDemandResponse(value, window)).toBe(false);
  });
  it.each<keyof DemandCounts>(["completed", "capacity_rejected", "timed_out", "latency_rejected", "failed", "cancelled", "unknown", "http_429"])("rejects a hidden %s count even when model outcome totals reconcile", field => {
    const value = snapshotForWindow("24h");
    value.models[0][field]++;
    if (field !== "http_429") value.models[0].requests++;
    expect(isModelDemandResponse(value, "24h")).toBe(false);
  });
  it("rejects outcome redistribution that leaves the request total unchanged", () => {
    const value = snapshotForWindow("24h");
    value.models[0].completed--;
    value.models[0].capacity_rejected++;
    expect(isModelDemandResponse(value, "24h")).toBe(false);
  });
  it("omits empty models rather than accepting positive residuals or measured zeros", () => {
    const value = snapshotForWindow("24h");
    value.models = [value.models[0]];
    value.models[0].time_series.forEach(bucket => { bucket.counts = null; });
    expect(isModelDemandResponse(value, "24h")).toBe(false);
    Object.assign(value.models[0], { requests: 0, completed: 0, capacity_rejected: 0, timed_out: 0, latency_rejected: 0, failed: 0, cancelled: 0, unknown: 0, http_429: 0 });
    expect(isModelDemandResponse(value, "24h")).toBe(false);
    value.models = [];
    expect(isModelDemandResponse(value, "24h")).toBe(true);
  });
  it.each<DemandWindow>(["24h", "7d", "30d"])("enforces the minimum published hourly count in %s display intervals", window => {
    const value = snapshotForWindow(window);
    const counts: DemandCounts = { requests: 20, completed: 20, capacity_rejected: 0, timed_out: 0, latency_rejected: 0, failed: 0, cancelled: 0, unknown: 0, http_429: 0 };
    value.models = [{ ...value.models[0], ...counts }];
    value.models[0].time_series[0].counts = counts;
    expect(isModelDemandResponse(value, window)).toBe(true);
    const belowThreshold = { ...counts, requests: 19, completed: 19 };
    Object.assign(value.models[0], belowThreshold);
    value.models[0].time_series[0].counts = belowThreshold;
    expect(isModelDemandResponse(value, window)).toBe(false);
    Object.assign(value.models[0], counts);
    value.models[0].time_series[0].counts = counts;
    value.models[0].time_series[1].counts = { ...counts, requests: 0, completed: 0 };
    expect(isModelDemandResponse(value, window)).toBe(false);
  });
  it("refuses nonreconciling totals and malformed timestamps", () => {
    expect(isModelDemandResponse(snapshot, "24h")).toBe(true);
    expect(isModelDemandResponse({ ...snapshot, end_at: "bad" }, "24h")).toBe(false);
    expect(isModelDemandResponse({ ...snapshot, models: [{ ...snapshot.models[0], requests: 101 }] }, "24h")).toBe(false);
    expect(isModelDemandResponse({ ...snapshot, models: [snapshot.models[0], snapshot.models[0]] }, "24h")).toBe(false);
    expect(isModelDemandResponse(snapshot, "7d")).toBe(false);
  });
});
