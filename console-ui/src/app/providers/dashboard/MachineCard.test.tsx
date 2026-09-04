// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MachineCard } from "./MachineCard";
import { makeModelNames, makeProvider, makeSlot, MOE_ID, MOE_NAME, QWEN27_ID, QWEN27_NAME } from "./testFixtures";
import { NO_MODEL_NAMES } from "./modelNames";
import type { RoutingCtx } from "./routing";

// The Remove button has its own behavioral test; here we only assert MachineCard
// gates the affordance by status, so stub the button to a marker.
vi.mock("./RemoveMachineButton", () => ({
  RemoveMachineButton: () => <div data-testid="remove-affordance" />,
}));

const ctx: RoutingCtx = {
  latest_provider_version: "0.6.5",
  min_provider_version: "0.6.0",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

const AFFORDANCE = "remove-affordance";

describe("MachineCard remove gating", () => {
  it("shows the Remove affordance for an offline machine", () => {
    render(<MachineCard provider={makeProvider({ status: "offline" })} ctx={ctx} fleetMaxDecodeTps={100} names={NO_MODEL_NAMES} />);
    expect(screen.getByTestId(AFFORDANCE)).toBeInTheDocument();
  });

  it("shows the Remove affordance for a never-seen machine", () => {
    render(<MachineCard provider={makeProvider({ status: "never_seen" })} ctx={ctx} fleetMaxDecodeTps={100} names={NO_MODEL_NAMES} />);
    expect(screen.getByTestId(AFFORDANCE)).toBeInTheDocument();
  });

  it("hides the Remove affordance for an online/serving machine", () => {
    render(
      <MachineCard
        provider={makeProvider({ status: "serving", online: true })}
        ctx={ctx}
        fleetMaxDecodeTps={100}
        names={NO_MODEL_NAMES}
      />
    );
    expect(screen.queryByTestId(AFFORDANCE)).toBeNull();
  });
});

describe("MachineCard model labels", () => {
  it("shows catalog display names on the loaded chips, catalog chips, and decode stand-in label", () => {
    const provider = makeProvider({
      status: "serving",
      online: true,
      current_model: QWEN27_ID,
      warm_models: [QWEN27_ID, MOE_ID],
      models: [{ id: QWEN27_ID }, { id: MOE_ID }],
      system_metrics: { memory_pressure: 0.62, cpu_usage: 0.09, thermal_state: "nominal" },
      backend_capacity: {
        slots: [makeSlot(MOE_ID, { observed_decode_tps: 88.4 }), makeSlot(QWEN27_ID, { state: "running", num_running: 1 })],
        gpu_memory_active_gb: 38.1,
        gpu_memory_peak_gb: 40,
        gpu_memory_cache_gb: 1.6,
        total_memory_gb: 64,
      },
    });
    render(<MachineCard provider={provider} ctx={ctx} fleetMaxDecodeTps={88.4} names={makeModelNames()} />);
    expect(screen.getAllByText(QWEN27_NAME).length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText(`on ${MOE_NAME}`)).toBeInTheDocument();
    expect(screen.queryByText("Qwen3.8-27B-4bit-mtp")).toBeNull();
  });
});
