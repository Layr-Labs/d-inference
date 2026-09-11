import { describe, expect, it } from "vitest";
import { render, screen, within } from "@testing-library/react";
import type { MyBackendCapacity } from "../types";
import { makeProvider } from "./testFixtures";
import { fleetActivity, loadedModels } from "./activity";
import { FleetActivity } from "./FleetActivity";
import { ModelsStrip } from "./ModelsStrip";
import { CardVitals } from "./CardVitals";

const cap: MyBackendCapacity = {
  slots: ["running", "idle", "crashed", "reloading", "idle_shutdown"].map((state) => ({
    model: state, state, num_running: state === "running" ? 2 : 0, num_waiting: state === "running" ? 1 : 0,
    active_tokens: 100, max_tokens_potential: 1000,
  })),
  gpu_memory_active_gb: 30, gpu_memory_cache_gb: 4, gpu_memory_peak_gb: 35, total_memory_gb: 64,
};
const online = makeProvider({ online: true, status: "serving", backend_capacity: cap, pending_requests: 3, warm_models: ["stale"] });

describe("fleet activity", () => {
  it("counts online activity once per model and keeps offline lifetime work", () => {
    const stats = fleetActivity([
      online,
      makeProvider({ id: "second", online: true, status: "online", warm_models: ["idle", "idle"] }),
      makeProvider({ id: "offline", pending_requests: 99, backend_capacity: cap }),
    ]);
    expect(stats).toMatchObject({ online: 2, serving: 1, requests: 3, queued: 1, queueReported: 1,
      loadedModels: 2, loadedCopies: 3, memoryGB: 128, lifetimeRequests: 12600, lifetimeTokens: 4500000 });
  });
  it("uses running and idle slots over stale warm/current hints, including empty snapshots", () => {
    expect(loadedModels(online)).toEqual(["running", "idle"]);
    expect(loadedModels({ ...online, backend_capacity: { ...cap, slots: [] } })).toEqual([]);
    expect(loadedModels({ ...online, online: false })).toEqual([]);
    expect(loadedModels({ ...online, backend_capacity: undefined, warm_models: [], current_model: "stale" })).toEqual([]);
  });
  it("shows missing RAM and queue coverage instead of invented zero measurements", () => {
    render(<FleetActivity providers={[makeProvider({ online: true, hardware: { memory_gb: undefined } })]} />);
    const memory = screen.getByText("Online memory").parentElement!;
    expect(within(memory).getByText("—")).toBeInTheDocument();
    expect(screen.getByText(/queue partially reported/)).toBeInTheDocument();
  });
  it("does not show failed or offline model slots as loaded or sleeping", () => {
    const { rerender } = render(<ModelsStrip provider={{ ...online, idle_unload_mins: 60, backend_capacity: { ...cap, slots: [cap.slots[2]] }, models: [{ id: "crashed" }] }} />);
    expect(screen.queryByText("Loaded")).not.toBeInTheDocument();
    expect(screen.queryByTestId("models-sleeping")).not.toBeInTheDocument();
    rerender(<ModelsStrip provider={{ ...online, online: false }} />);
    expect(screen.queryByText("Loaded")).not.toBeInTheDocument();
  });
  it("does not render historical offline telemetry as live", () => {
    render(<CardVitals provider={{ ...online, online: false }} fleetMaxDecodeTps={100} />);
    expect(screen.getByText(/No live metrics/)).toBeInTheDocument();
    expect(screen.queryByText("GPU memory")).not.toBeInTheDocument();
  });
});
