// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { CardVitals } from "./CardVitals";
import { makeProvider } from "./testFixtures";
import type { MyBackendCapacity, MyProvider } from "../types";

const cap: MyBackendCapacity = {
  slots: [
    { model: "qwen-35b-a3b", state: "idle", num_running: 0, num_waiting: 0, active_tokens: 0, max_tokens_potential: 8192, observed_decode_tps: 92 },
    { model: "qwen-27b", state: "running", num_running: 1, num_waiting: 0, active_tokens: 512, max_tokens_potential: 8192, observed_decode_tps: 31.5, observed_prefill_tps: 1400 },
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
    current_model: "qwen-27b",
    system_metrics: { memory_pressure: 0.62, cpu_usage: 0.09, thermal_state: "nominal" },
    backend_capacity: cap,
    pending_requests: 1,
    max_concurrency: 24,
    ...overrides,
  });
}

describe("CardVitals decode line", () => {
  it("renders the coordinator-resolved decode and prefill rates", () => {
    render(<CardVitals provider={liveProvider({ decode_tps: 31.5, prefill_tps: 1400 })} fleetMaxDecodeTps={92} />);
    expect(screen.getByText("31.5")).toBeInTheDocument();
    expect(screen.getByText("prefill 1400")).toBeInTheDocument();
    expect(screen.getByLabelText("Decode 31.5 tokens per second")).toBeInTheDocument();
  });

  it("renders the active slot's EWMA when decode_tps is absent from the payload", () => {
    render(<CardVitals provider={liveProvider()} fleetMaxDecodeTps={92} />);
    expect(screen.getByText("31.5")).toBeInTheDocument();
    expect(screen.getByText("prefill 1400")).toBeInTheDocument();
  });

  it("renders an explicit blank, not a zero, for an unmeasured machine", () => {
    const unmeasured = liveProvider({
      backend_capacity: { ...cap, slots: cap.slots.map((s) => ({ ...s, observed_decode_tps: undefined, observed_prefill_tps: undefined })) },
    });
    render(<CardVitals provider={unmeasured} fleetMaxDecodeTps={0} />);
    expect(screen.getByText("—")).toBeInTheDocument();
    expect(screen.queryByText(/^prefill/)).toBeNull();
  });
});
