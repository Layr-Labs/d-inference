import { describe, expect, it } from "vitest";
import {
  catalogModelsFromResponse,
  capacityModelsFromResponse,
  filterServedCatalogModels,
} from "@/lib/stats-model-filter";

const gptModel = "gpt-oss-20b";

describe("filterServedCatalogModels", () => {
  const gemmaModel = "gemma-4-26b";
  const statsModels = [
    { id: gptModel, providers: 17 },
    { id: gemmaModel, providers: 14 },
    { id: "stale-provider-model", providers: 9 },
  ];

  const catalogModels = [
    { id: gptModel, status: "active" },
    { id: gemmaModel, status: "active" },
  ];

  it("shows only served catalog models by default", () => {
    const result = filterServedCatalogModels(statsModels, catalogModels, false);

    expect(result.visible.map((model) => model.id)).toEqual([
      gptModel,
      gemmaModel,
    ]);
    expect(result.deprecatedCount).toBe(1);
  });

  it("includes served non-catalog models when deprecated models are enabled", () => {
    const result = filterServedCatalogModels(statsModels, catalogModels, true);

    expect(result.visible.map((model) => [model.id, model.catalogStatus])).toEqual([
      [gptModel, "active"],
      [gemmaModel, "active"],
      ["stale-provider-model", "deprecated"],
    ]);
  });
});

describe("catalogModelsFromResponse", () => {
  it("normalizes Next proxy and coordinator catalog responses", () => {
    expect(
      catalogModelsFromResponse({
        data: [
          {
            id: "proxy-active",
            metadata: {
              status: "active",
              display_name: "Proxy Active",
              size_gb: 12.5,
            },
          },
          { id: "proxy-deprecated", metadata: { status: "deprecated" } },
        ],
      }),
    ).toEqual([
      {
        id: "proxy-active",
        status: "active",
        displayName: "Proxy Active",
        sizeGB: 12.5,
      },
      { id: "proxy-deprecated", status: "deprecated" },
    ]);

    expect(
      catalogModelsFromResponse({
        models: [
          { id: "coordinator-active", status: "active" },
        ],
      }),
    ).toEqual([{ id: "coordinator-active", status: "active" }]);
  });
});

describe("capacityModelsFromResponse", () => {
  it("normalizes model capacity analytics", () => {
    expect(
      capacityModelsFromResponse({
        models: [
          {
            id: gptModel,
            ready: true,
            can_accept: true,
            routable_providers: 5,
            warm_providers: 1,
            cold_providers: 4,
            active_requests: 2,
            queued_requests: 3,
            queue_limit: 10,
            aggregate_tps: 137.8,
            estimated_ttft_ms: 24367,
            token_budget_remaining: 42,
            token_budget_total: 100,
          },
        ],
      }),
    ).toEqual([
      {
        id: gptModel,
        ready: true,
        canAccept: true,
        routableProviders: 5,
        warmProviders: 1,
        coldProviders: 4,
        activeRequests: 2,
        queuedRequests: 3,
        queueLimit: 10,
        aggregateTPS: 137.8,
        estimatedTTFTMS: 24367,
        tokenBudgetRemaining: 42,
        tokenBudgetTotal: 100,
      },
    ]);
  });
});
