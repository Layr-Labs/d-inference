// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { CardVitals } from "./CardVitals";
import { makeProvider } from "./testFixtures";
import { modelNamesFrom } from "./modelNames";
import type { MyBackendCapacity, MyBackendSlot, MyProvider } from "../types";

const ACTIVE = "qwen-27b";
const MOE = "qwen-35b-a3b";

function slot(model: string, overrides: Partial<MyBackendSlot> = {}): MyBackendSlot {
  return { model, state: "idle", num_running: 0, num_waiting: 0, active_tokens: 0, max_tokens_potential: 8192, ...overrides };
}

const cap: MyBackendCapacity = {
  slots: [
    slot(MOE, { observed_decode_tps: 92 }),
    slot(ACTIVE, { state: "running", num_running: 1, active_tokens: 512, observed_decode_tps: 31.5, observed_prefill_tps: 1400 }),
  ],
  gpu_memory_active_gb: 38.1,
  gpu_memory_peak_gb: 40,
  gpu_memory_cache_gb: 1.6,
  total_memory_gb: 64,
};

function liveProvider(overrides: Partial<MyProvider> = {}): MyProvider {
  return makeProvider({
    status: "serving",
    online: true,
    current_model: ACTIVE,
    system_metrics: { memory_pressure: 0.62, cpu_usage: 0.09, thermal_state: "nominal" },
    backend_capacity: cap,
    pending_requests: 1,
    max_concurrency: 24,
    ...overrides,
  });
}

describe("CardVitals decode line", () => {
  it("renders the active model's measured decode and prefill rates without attribution", () => {
    render(<CardVitals provider={liveProvider({ decode_tps: 31.5, prefill_tps: 1400 })} fleetMaxDecodeTps={92} />);
    expect(screen.getByText("31.5")).toBeInTheDocument();
    expect(screen.getByText("prefill 1400")).toBeInTheDocument();
    expect(screen.getByLabelText("Decode 31.5 tokens per second")).toBeInTheDocument();
    expect(screen.queryByText(/^on /)).toBeNull();
  });

  it("renders the same figure when decode_tps is absent from the payload", () => {
    render(<CardVitals provider={liveProvider()} fleetMaxDecodeTps={92} />);
    expect(screen.getByText("31.5")).toBeInTheDocument();
    expect(screen.getByText("prefill 1400")).toBeInTheDocument();
  });

  it("names the stand-in model when the active slot has not been measured yet", () => {
    const swappedIn = liveProvider({
      decode_tps: 92,
      backend_capacity: { ...cap, slots: [slot(MOE, { observed_decode_tps: 92 }), slot(ACTIVE, { state: "running", num_running: 1 })] },
    });
    render(<CardVitals provider={swappedIn} fleetMaxDecodeTps={92} />);
    expect(screen.getByText("92.0")).toBeInTheDocument();
    expect(screen.getByText(`on ${MOE}`)).toBeInTheDocument();
  });

  it("uses the catalog display name for the stand-in model, raw id in the tooltip", () => {
    const swappedIn = liveProvider({
      backend_capacity: { ...cap, slots: [slot(MOE, { observed_decode_tps: 92 }), slot(ACTIVE, { state: "running", num_running: 1 })] },
    });
    const names = modelNamesFrom({ model_display_names: { [MOE]: "Qwen 3.6 35B A3B" } });
    render(<CardVitals provider={swappedIn} fleetMaxDecodeTps={92} names={names} />);
    const label = screen.getByText("on Qwen 3.6 35B A3B");
    expect(label).toBeInTheDocument();
    expect(label.getAttribute("title")).toContain(MOE);
  });

  it("renders an explicit blank, not a zero, for an unmeasured machine", () => {
    const unmeasured = liveProvider({ backend_capacity: { ...cap, slots: [slot(MOE), slot(ACTIVE, { state: "running", num_running: 1 })] } });
    render(<CardVitals provider={unmeasured} fleetMaxDecodeTps={0} />);
    expect(screen.getByText("—")).toBeInTheDocument();
    expect(screen.queryByText(/^prefill/)).toBeNull();
    expect(screen.queryByText(/^on /)).toBeNull();
  });
});
