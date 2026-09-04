import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrafficPanel } from "./TrafficPanel";
const snapshotAt = "2026-09-04T12:30:00Z";
const data = [{ timestamp: "2026-09-04T12:29:00Z", requests: 3, prompt_tokens: 5, completion_tokens: 2, active_providers: 1 }];
const response = (window = "30m") => new Response(JSON.stringify({window, end_at:snapshotAt, time_series:data}), {status:200});
afterEach(() => vi.unstubAllGlobals());
describe("Traffic exploration", () => {
  it("uses explicit time boundaries and supports keyboard inspection", async () => {
    const fetchMock = vi.fn().mockResolvedValue(response());
    vi.stubGlobal("fetch", fetchMock);
    render(<TrafficPanel refreshToken="2026-09-04T12:32:00Z" />);
    await screen.findByRole("group", {name:"Requests traffic chart"});
    expect(fetchMock).toHaveBeenCalledWith("/api/network/series?window=30m", expect.any(Object));
    const plot = screen.getByRole("group", { name: "Tokens traffic chart" });
    fireEvent.focus(plot);
    expect(screen.getByText("7 tokens")).toBeInTheDocument();
    fireEvent.keyDown(plot, { key: "Home" });
    expect(screen.getByText("0 tokens")).toBeInTheDocument();
  });
  it("shows failed historical requests as unavailable and supports retry", async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(response()).mockResolvedValueOnce(new Response(null,{status:503})).mockResolvedValueOnce(response("24h"));
    vi.stubGlobal("fetch",fetchMock);
    render(<TrafficPanel refreshToken={snapshotAt} />);
    await screen.findByRole("group", {name:"Requests traffic chart"});
    fireEvent.click(screen.getByRole("button", {name:"24h"}));
    expect(await screen.findByText("Activity couldn’t be loaded.")).toBeInTheDocument();
    expect(screen.queryByRole("group",{name:"Requests traffic chart"})).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button",{name:"Try again"}));
    await waitFor(()=>expect(screen.getByRole("group",{name:"Requests traffic chart"})).toBeInTheDocument());
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
  it("rejects history without a valid boundary instead of plotting relative to now", async () => {
    vi.stubGlobal("fetch",vi.fn().mockResolvedValue(new Response(JSON.stringify({window:"30m",time_series:data}),{status:200})));
    render(<TrafficPanel refreshToken={snapshotAt} />);
    expect(await screen.findByText("Activity couldn’t be loaded.")).toBeInTheDocument();
    expect(screen.queryByRole("group",{name:"Requests traffic chart"})).not.toBeInTheDocument();
  });
});
