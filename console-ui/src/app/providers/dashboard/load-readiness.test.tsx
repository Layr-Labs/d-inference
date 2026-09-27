// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { makeProvider } from "./testFixtures";
import { coldModelReadiness } from "./load-readiness";
import { LoadReadinessPanel } from "./LoadReadinessPanel";
import { ModelsStrip } from "./ModelsStrip";
import { computeWarnings } from "../warnings";
import { resolveFix } from "./fixes";

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
    capacity_accepted_at: new Date().toISOString(),
    models: [{ id: "EigenLabs/Qwen3.8-27B-4bit-mtp", estimated_memory_gb: 18.2 }],
    capacity_model_ids: ["EigenLabs/Qwen3.8-27B-4bit-mtp"],
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
    const warning = computeWarnings(cold, ctx).find((item) => item.id === "model_load_memory");
    expect(resolveFix(warning!.id)).toEqual(expect.objectContaining({
      kind: "command", command: "darkbloom doctor",
      note: expect.stringContaining("retry a request for this model"),
    }));
  });

  it("does not infer failure from legacy, offline, or resident snapshots", () => {
    for (const provider of [
      makeProvider({ ...cold, backend_capacity: { ...cap, load_usable_gb: undefined } }),
      makeProvider({ ...cold, online: false, status: "offline" }),
      makeProvider({ ...cold, capacity_accepted_at: undefined }),
      makeProvider({ ...cold, backend_capacity: { ...cap, slots: [{ model: cold.models[0].id,
        state: "idle", num_running: 0, num_waiting: 0, active_tokens: 0, max_tokens_potential: 1000 }] } }),
    ]) {
      expect(coldModelReadiness(provider)).toEqual([]);
      expect(computeWarnings(provider, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
    }
    const staleWarm = makeProvider({ ...cold, warm_models: [cold.models[0].id], current_model: cold.models[0].id });
    expect(coldModelReadiness(staleWarm)).toHaveLength(1);
    render(<ModelsStrip provider={staleWarm} />);
    expect(screen.queryByText("Loaded")).toBeNull();
  });

  it("separates a no-eviction preload skip from a request that can evict idle slots", () => {
    const withResidentSlot = makeProvider({
      ...cold,
      models: [...cold.models, { id: "small", estimated_memory_gb: 3 }],
      capacity_model_ids: [cold.models[0].id, "small"],
      warm_models: ["small"],
      backend_capacity: { ...cap, free_for_load_gb: 19,
        slots: [{ model: "small", state: "idle", num_running: 0,
          num_waiting: 0, active_tokens: 0, max_tokens_potential: 1000 }] },
    });
    expect(coldModelReadiness(withResidentSlot)[0].canLoadAfterEviction).toBe(true);
    render(<LoadReadinessPanel provider={withResidentSlot} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText("Preload blocked")).toBeInTheDocument();
    expect(screen.getByText(/request may load it after evicting idle models/)).toBeInTheDocument();
    expect(computeWarnings(withResidentSlot, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
  });

  it("withholds stale samples and a temporary shortage during active inference", () => {
    const stale = makeProvider({ ...cold,
      capacity_accepted_at: new Date(Date.now() - 120_000).toISOString(),
      last_heartbeat: new Date().toISOString() });
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
    expect(screen.getByText("Temporarily busy")).toBeInTheDocument();
    expect(screen.getByText(/A request is active or queued/)).toBeInTheDocument();

    const queued = makeProvider({ ...cold,
      backend_capacity: { ...cap, slots: [{ model: "small", state: "idle", num_running: 0,
        num_waiting: 1, active_tokens: 0, max_tokens_potential: 1000 }] },
    });
    expect(coldModelReadiness(queued)[0].busyServing).toBe(true);
    expect(computeWarnings(queued, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
  });

  it("withholds a memory failure while a startup load has no slot yet", () => {
    const loading = makeProvider({ ...cold,
      backend_capacity: { ...cap, load_transition_active: true, slots: [] },
    });
    expect(coldModelReadiness(loading)[0].busyServing).toBe(true);
    expect(computeWarnings(loading, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
    render(<LoadReadinessPanel provider={loading} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText("Temporarily busy")).toBeInTheDocument();
  });

  it("recommends a request retry independent of preload configuration", () => {
    render(<LoadReadinessPanel provider={cold} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText(/then retry a request for this model/)).toBeInTheDocument();
    expect(computeWarnings(cold, ctx).find((warning) => warning.id === "model_load_memory")?.detail)
      .toContain("then retry a request for this model");
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

  it("does not diagnose an off-catalog model from canonical capacity", () => {
    const ownerOnly = makeProvider({ ...cold,
      models: [{ id: "owner-only", estimated_memory_gb: 18.2 }],
      capacity_model_ids: [],
    });
    expect(coldModelReadiness(ownerOnly)).toEqual([]);
    expect(computeWarnings(ownerOnly, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);

    const mixed = makeProvider({ ...cold,
      models: [...cold.models, { id: "owner-only", estimated_memory_gb: 18.2 }],
      capacity_model_ids: [cold.models[0].id],
    });
    expect(coldModelReadiness(mixed)).toHaveLength(1);
    expect(computeWarnings(mixed, ctx).find((warning) => warning.id === "model_load_memory")?.severity)
      .toBe("blocking");
  });

  it("withholds a memory failure while a model slot is reloading", () => {
    const reloading = makeProvider({ ...cold,
      backend_capacity: { ...cap, slots: [{ model: cold.models[0].id,
        state: "reloading", num_running: 0, num_waiting: 0,
        active_tokens: 0, max_tokens_potential: 1000 }] },
    });
    expect(coldModelReadiness(reloading)[0].busyServing).toBe(true);
    expect(computeWarnings(reloading, ctx).some((warning) => warning.id === "model_load_memory")).toBe(false);
    render(<LoadReadinessPanel provider={reloading} heartbeatTimeoutSeconds={90} />);
    expect(screen.getByText("Temporarily busy")).toBeInTheDocument();
  });

  it("keeps a crashed resident model out of the cold-load warning", () => {
    const crashed = makeProvider({ ...cold,
      backend_capacity: { ...cap, slots: [{ model: cold.models[0].id,
        state: "crashed", num_running: 0, num_waiting: 0,
        active_tokens: 0, max_tokens_potential: 0 }] },
    });
    expect(coldModelReadiness(crashed)).toEqual([]);
    const warnings = computeWarnings(crashed, ctx);
    expect(warnings.some((warning) => warning.id === "model_load_memory")).toBe(false);
    expect(warnings.some((warning) => warning.id === "backend_crashed")).toBe(true);
  });

  it("shows crashed and reloading slots in the compact model strip", () => {
    const provider = makeProvider({ ...cold,
      models: [...cold.models, { id: "second", estimated_memory_gb: 3 }],
      backend_capacity: { ...cap, slots: [
        { model: cold.models[0].id, state: "crashed", num_running: 0, num_waiting: 0,
          active_tokens: 0, max_tokens_potential: 0 },
        { model: "second", state: "reloading", num_running: 0, num_waiting: 0,
          active_tokens: 0, max_tokens_potential: 0 },
      ] },
    });
    render(<ModelsStrip provider={provider} />);
    expect(screen.getByText("Loaded")).toBeInTheDocument();
    expect(screen.getByText("crashed")).toBeInTheDocument();
    expect(screen.getByText("reloading")).toBeInTheDocument();
  });
});
