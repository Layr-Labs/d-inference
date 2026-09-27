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
    models: [{ id: "EigenLabs/Qwen3.8-27B-4bit-mtp", estimated_memory_gb: 18.2 }],
    backend_capacity: cap,
  });

  it("shows the exact no-eviction load gap and an actionable warning", () => {
    const readiness = coldModelReadiness(cold);
    expect(readiness).toHaveLength(1);
    expect(readiness[0].requiredGb).toBeCloseTo(24.7);
    expect(readiness[0].shortfallGb).toBeCloseTo(10.4);
    render(<LoadReadinessPanel provider={cold} />);
    expect(screen.getByText("Cannot cold-load now")).toBeInTheDocument();
    expect(screen.getByText(/24\.7 GB needed/)).toBeInTheDocument();
    expect(screen.getByText(/10\.4 GB short/)).toBeInTheDocument();
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
    render(<LoadReadinessPanel provider={withResidentSlot} />);
    expect(screen.getByText("Preload blocked")).toBeInTheDocument();
    expect(screen.getByText(/request may load it after evicting idle models/)).toBeInTheDocument();
    expect(computeWarnings(withResidentSlot, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
  });
});
