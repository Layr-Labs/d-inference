// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { makeProvider } from "./testFixtures";
import { coldModelReadiness } from "./load-readiness";
import { LoadReadinessPanel } from "./LoadReadinessPanel";
import { computeWarnings } from "../warnings";

const cap = {
  slots: [], gpu_memory_active_gb: 0, gpu_memory_peak_gb: 0,
  gpu_memory_cache_gb: 0, total_memory_gb: 48,
  load_usable_gb: 14.3, load_headroom_gb: 6.5,
  free_for_load_gb: 7.8,
};
const ctx = {
  latest_provider_version: "0.9.10", min_provider_version: "0.9.9",
  heartbeat_timeout_seconds: 90, challenge_max_age_seconds: 360,
};

describe("owner model load readiness", () => {
  const cold = makeProvider({
    status: "serving", online: true, idle_unload_mins: 0,
    last_heartbeat: new Date().toISOString(),
    models: [{ id: "EigenLabs/Qwen3.8-27B-4bit-mtp", estimated_memory_gb: 18.2 }],
    backend_capacity: cap,
  });

  it("shows the exact no-eviction load gap and an actionable warning", () => {
    const readiness = coldModelReadiness(cold);
    expect(readiness).toHaveLength(1);
    expect(readiness[0].requiredGb).toBeCloseTo(24.7);
    expect(readiness[0].shortfallGb).toBeCloseTo(10.4);
    render(<LoadReadinessPanel provider={cold} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText("Cannot cold-load now")).toBeInTheDocument();
    expect(screen.getByText(/24\.7 GB needed/)).toBeInTheDocument();
    expect(screen.getByText(/10\.4 GB short without eviction/)).toBeInTheDocument();
    expect(screen.getByText(/Still 10\.4 GB short after idle eviction/)).toBeInTheDocument();
    expect(computeWarnings(cold, ctx)).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "model_load_memory", severity: "blocking" }),
    ]));
  });

  it("does not infer failure from legacy, offline, or resident snapshots", () => {
    for (const provider of [
      makeProvider({ ...cold, backend_capacity: { ...cap, load_usable_gb: undefined } }),
      makeProvider({ ...cold, online: false, status: "offline" }),
      makeProvider({ ...cold, warm_models: [cold.models[0].id] }),
    ]) {
      expect(coldModelReadiness(provider)).toEqual([]);
      expect(computeWarnings(provider, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
    }
  });

  it("separates a no-eviction preload skip from a request that can evict idle slots", () => {
    const withResidentSlot = makeProvider({
      ...cold,
      models: [...cold.models, { id: "small", estimated_memory_gb: 3 }],
      warm_models: ["small"],
      backend_capacity: { ...cap, free_for_load_gb: 19 },
    });
    expect(coldModelReadiness(withResidentSlot)[0].canLoadAfterEviction).toBe(true);
    render(<LoadReadinessPanel provider={withResidentSlot} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText("Preload blocked")).toBeInTheDocument();
    expect(screen.getByText(/request may load it after evicting idle models/)).toBeInTheDocument();
    expect(computeWarnings(withResidentSlot, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
  });

  it("withholds stale samples and a temporary shortage during active inference", () => {
    const stale = makeProvider({ ...cold, last_heartbeat: new Date(Date.now() - 120_000).toISOString() });
    expect(coldModelReadiness(stale)).toEqual([]);
    expect(computeWarnings(stale, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);

    const busy = makeProvider({
      ...cold,
      backend_capacity: { ...cap, slots: [{ model: "small", state: "running", num_running: 1,
        num_waiting: 0, active_tokens: 100, max_tokens_potential: 1000 }] },
    });
    expect(coldModelReadiness(busy)[0].busyServing).toBe(true);
    expect(computeWarnings(busy, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
    render(<LoadReadinessPanel provider={busy} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText("Busy serving")).toBeInTheDocument();
    expect(screen.getByText(/Recheck this load budget when the Mac is idle/)).toBeInTheDocument();
  });

  it("uses the eviction-aware gap for the remedy", () => {
    const partlyReclaimable = makeProvider({ ...cold,
      backend_capacity: { ...cap, free_for_load_gb: 14 },
    });
    const readiness = coldModelReadiness(partlyReclaimable)[0];
    expect(readiness.shortfallGb).toBeCloseTo(10.4);
    expect(readiness.coldLoadShortfallGb).toBeCloseTo(4.2);
    render(<LoadReadinessPanel provider={partlyReclaimable} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText(/Still 4\.2 GB short after idle eviction/)).toBeInTheDocument();
    expect(screen.getByText(/Free at least 4\.2 GB/)).toBeInTheDocument();
    expect(computeWarnings(partlyReclaimable, ctx).find((warning) => warning.id === "model_load_memory")?.detail)
      .toContain("4.2 GB short");
  });
});
