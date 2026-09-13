import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { PlatformStats } from "../platform-types";
import type { ProviderStats } from "../provider-fleet";
import { ModelCapacityLandscape } from "./ModelCapacityLandscape";
import { prepareModelInventory } from "./model-inventory";

const firstName = "Qwen 3 30B A3B Instruct";
const secondName = "Gemma 4 26B";
const node: ProviderStats = { id: "node-1", chip: "M4 Max", chip_family: "M4", chip_tier: "Max", machine_model: "Mac Studio", memory_gb: 64, gpu_cores: 40, cpu_cores: { total: 16, performance: 12, efficiency: 4 }, memory_bandwidth_gbs: 546, status: "online", trust_level: "hardware", decode_tps: 25, requests_served: 1, tokens_generated: 20, models: ["qwen3", "gemma4"] };
const providers = Array.from({ length: 10 }, (_, index) => ({ ...node, id: `node-${index}`, models: index < 5 ? ["qwen3", "gemma4"] : ["qwen3"] }));
const stats: PlatformStats = { total_requests: 1, total_prompt_tokens: 1, total_completion_tokens: 20, total_tokens: 21, avg_tokens_per_request: 21, active_providers: 10, total_gpu_cores: 400, total_cpu_cores: 160, total_memory_gb: 640, total_bandwidth_gbs: 5460, network_capacity_tps: 250, providers, models: [{ id: "qwen3", providers: 10 }, { id: "gemma4", providers: 5 }], time_series: [] };
const catalog = { models: [{ id: "qwen3", status: "active", displayName: firstName }, { id: "gemma4", status: "active", displayName: secondName }], aliases: [] };
const capacity = [{ id: "qwen3", routableProviders: 5, canAccept: true, activeRequests: 7, queuedRequests: 2, aggregateTPS: 200 }, { id: "gemma4", routableProviders: 0, canAccept: false, activeRequests: 0, queuedRequests: 0, aggregateTPS: 80 }];

describe("Model capacity landscape", () => {
  it("shows every model on a common node scale and keeps request counts separate", () => {
    render(<ModelCapacityLandscape stats={stats} catalogData={catalog} capacityModels={capacity} />);
    expect(screen.getByText(firstName)).toBeInTheDocument();
    expect(screen.getByText(secondName)).toBeInTheDocument();
    const firstLane = screen.getByRole("img", { name: `${firstName}: 5 accepting of 10 connected nodes. Shared scale 0 to 10 nodes.` });
    const secondLane = screen.getByRole("img", { name: `${secondName}: 0 accepting of 5 connected nodes. Shared scale 0 to 10 nodes.` });
    expect([...firstLane.querySelectorAll("rect")].map((rect) => rect.getAttribute("width"))).toEqual(["600", "300"]);
    expect([...secondLane.querySelectorAll("rect")].map((rect) => rect.getAttribute("width"))).toEqual(["300", "0"]);
    expect(screen.getByText("7 active requests")).toBeInTheDocument();
    expect(screen.getByText("2 queued")).toBeInTheDocument();
    expect(screen.getAllByText("Estimated generation")).toHaveLength(2);
  });

  it("preserves unknown capacity distinctly from known zero", () => {
    const view = render(<ModelCapacityLandscape stats={stats} catalogData={catalog} capacityModels={null} />);
    expect(screen.getByRole("img", { name: `${firstName}: accepting capacity unknown; 10 connected nodes. Shared scale 0 to 10 nodes.` })).toBeInTheDocument();
    expect(screen.getAllByText("Request load not reported")).toHaveLength(2);
    fireEvent.click(screen.getByRole("button", { name: `Show capacity details for ${firstName}` }));
    expect(screen.getByText("In progress").nextElementSibling).toHaveTextContent("—");
    fireEvent.click(screen.getByRole("button", { name: `Hide capacity details for ${firstName}` }));
    expect(screen.queryByRole("region", { name: `${firstName} capacity details` })).not.toBeInTheDocument();
    view.rerender(<ModelCapacityLandscape stats={stats} catalogData={catalog} capacityModels={[]} />);
    expect(screen.getByRole("img", { name: `${firstName}: 0 accepting of 10 connected nodes. Shared scale 0 to 10 nodes.` })).toBeInTheDocument();
    expect(screen.queryByText("Accepting capacity unknown")).not.toBeInTheDocument();
  });

  it("opens one model diagnostic inline without hiding other lanes", () => {
    render(<ModelCapacityLandscape stats={stats} catalogData={catalog} capacityModels={capacity} />);
    fireEvent.click(screen.getByRole("button", { name: `Show capacity details for ${firstName}` }));
    expect(screen.getByRole("region", { name: `${firstName} capacity details` })).toBeInTheDocument();
    expect(screen.getByText("Not published per node")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: `Show capacity details for ${secondName}` }));
    expect(screen.queryByRole("region", { name: `${firstName} capacity details` })).not.toBeInTheDocument();
    expect(screen.getByRole("region", { name: `${secondName} capacity details` })).toBeInTheDocument();
    expect(screen.getAllByRole("img", { name: /Shared scale/ })).toHaveLength(2);
  });


  it("keeps deprecated models hidden until explicitly included", () => {
    const withRetired = { ...stats, models: [...stats.models, { id: "retired", providers: 1 }] };
    render(<ModelCapacityLandscape stats={withRetired} catalogData={catalog} capacityModels={[]} />);
    const retiredButton = "Show capacity details for retired";
    expect(screen.queryByRole("button", { name: retiredButton })).not.toBeInTheDocument();
    const toggle = screen.getByRole("checkbox", { name: "Include deprecated models in capacity chart" });
    fireEvent.click(toggle);
    expect(screen.getByRole("button", { name: retiredButton })).toBeInTheDocument();
    fireEvent.click(toggle);
    expect(screen.queryByRole("button", { name: retiredButton })).not.toBeInTheDocument();
  });

  it("does not infer routing or suppress capacity from stale public verification fields", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-13T01:30:00Z"));
    try {
      const staleProviders = providers.map((provider) => ({ ...provider, routable: undefined, runtime_verified: true, last_challenge_verified: "2026-07-13T01:00:00Z" }));
      const publicStats = { ...stats, providers: staleProviders };
      const inventory = prepareModelInventory(publicStats, catalog, capacity, false);
      expect(inventory.models[0].routable).toBeUndefined();
      render(<ModelCapacityLandscape stats={publicStats} catalogData={catalog} capacityModels={capacity} />);
      expect(screen.getByRole("img", { name: `${firstName}: 5 accepting of 10 connected nodes. Shared scale 0 to 10 nodes.` })).toBeInTheDocument();
      fireEvent.click(screen.getByRole("button", { name: `Show capacity details for ${firstName}` }));
      expect(screen.getByText("Routing eligible").nextElementSibling).toHaveTextContent("—");
      expect(screen.getByText("Not published per node")).toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("deduplicates alias providers and excludes retired builds from capacity", () => {
    const builds = { current: "build-new", previous: "build-old", retired: "build-retired" };
    const allBuilds = Object.values(builds);
    const aliasStats = { ...stats, providers: [{ ...node, models: allBuilds }], models: allBuilds.map((id) => ({ id, providers: 1 })) };
    const aliasCatalog = { models: [{ id: builds.current, status: "active", displayName: "Alias model" }], aliases: [{ id: "public-model", desiredBuild: builds.current, previousBuild: builds.previous, retiredBuilds: [builds.retired] }] };
    const aliasCapacity = [{ id: builds.current, routableProviders: 1, canAccept: true }, { id: builds.previous, routableProviders: 1, canAccept: true }, { id: builds.retired, routableProviders: 10, canAccept: true }];
    const inventory = prepareModelInventory(aliasStats, aliasCatalog, aliasCapacity, false);
    expect(inventory.models).toHaveLength(1);
    expect(inventory.models[0].providers).toBe(1);
    expect(inventory.models[0].capacity?.routableProviders).toBe(2);
    render(<ModelCapacityLandscape stats={aliasStats} catalogData={aliasCatalog} capacityModels={aliasCapacity} />);
    expect(screen.getByRole("img", { name: "Alias model: 1 accepting of 1 connected nodes. Shared scale 0 to 1 nodes." })).toBeInTheDocument();
  });
});
