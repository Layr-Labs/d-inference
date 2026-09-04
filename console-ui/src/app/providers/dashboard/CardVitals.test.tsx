// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { CardVitals } from "./CardVitals";
import { makeModelNames, makeProvider, makeSlot, MOE_ID, MOE_NAME, QWEN27_ID } from "./testFixtures";
import { NO_MODEL_NAMES } from "./modelNames";
import type { MyBackendCapacity, MyProvider } from "../types";

const cap: MyBackendCapacity = {
  slots: [
    makeSlot(MOE_ID, { observed_decode_tps: 92 }),
    makeSlot(QWEN27_ID, { state: "running", num_running: 1, active_tokens: 512, observed_decode_tps: 31.5, observed_prefill_tps: 1400 }),
  ],
  gpu_memory_active_gb: 38.1,
  gpu_memory_peak_gb: 40,
  gpu_memory_cache_gb: 1.6,
  total_memory_gb: 64,
};

/** The active 27B slot has served nothing yet; the MoE slot has. */
const swappedInCap: MyBackendCapacity = {
  ...cap,
  slots: [makeSlot(MOE_ID, { observed_decode_tps: 92 }), makeSlot(QWEN27_ID, { state: "running", num_running: 1 })],
};

function liveProvider(overrides: Partial<MyProvider> = {}): MyProvider {
  return makeProvider({
    status: "serving",
    online: true,
    current_model: QWEN27_ID,
    system_metrics: { memory_pressure: 0.62, cpu_usage: 0.09, thermal_state: "nominal" },
    backend_capacity: cap,
    pending_requests: 1,
    max_concurrency: 24,
    ...overrides,
  });
}

describe("CardVitals decode line", () => {
  it("renders the active model's measured decode and prefill rates without attribution", () => {
    render(<CardVitals provider={liveProvider({ decode_tps: 31.5, prefill_tps: 1400 })} fleetMaxDecodeTps={92} names={NO_MODEL_NAMES} />);
    expect(screen.getByText("31.5")).toBeInTheDocument();
    expect(screen.getByText("prefill 1400")).toBeInTheDocument();
    expect(screen.getByLabelText("Decode 31.5 tokens per second")).toBeInTheDocument();
    expect(screen.queryByText(/^on /)).toBeNull();
  });

  it("renders the same figure when decode_tps is absent from the payload", () => {
    render(<CardVitals provider={liveProvider()} fleetMaxDecodeTps={92} names={NO_MODEL_NAMES} />);
    expect(screen.getByText("31.5")).toBeInTheDocument();
    expect(screen.getByText("prefill 1400")).toBeInTheDocument();
  });

  it("names the stand-in model when the active slot has not been measured yet", () => {
    render(<CardVitals provider={liveProvider({ decode_tps: 92, backend_capacity: swappedInCap })} fleetMaxDecodeTps={92} names={NO_MODEL_NAMES} />);
    expect(screen.getByText("92.0")).toBeInTheDocument();
    expect(screen.getByText(`on ${MOE_ID}`)).toBeInTheDocument();
  });

  it("uses the catalog display name for the stand-in model, raw id in the tooltip", () => {
    render(<CardVitals provider={liveProvider({ backend_capacity: swappedInCap })} fleetMaxDecodeTps={92} names={makeModelNames()} />);
    const label = screen.getByText(`on ${MOE_NAME}`);
    expect(label).toBeInTheDocument();
    expect(label.getAttribute("title")).toContain(MOE_ID);
  });

  it("renders an explicit blank, not a zero, for an unmeasured machine", () => {
    const unmeasured = liveProvider({
      backend_capacity: { ...cap, slots: [makeSlot(MOE_ID), makeSlot(QWEN27_ID, { state: "running", num_running: 1 })] },
    });
    render(<CardVitals provider={unmeasured} fleetMaxDecodeTps={0} names={NO_MODEL_NAMES} />);
    expect(screen.getByText("—")).toBeInTheDocument();
    expect(screen.queryByText(/^prefill/)).toBeNull();
    expect(screen.queryByText(/^on /)).toBeNull();
  });
});
