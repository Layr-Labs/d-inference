import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import StatsPage from "./page";

const stats = {
  total_requests: 10,
  total_prompt_tokens: 20,
  total_completion_tokens: 10,
  total_tokens: 30,
  avg_tokens_per_request: 3,
  active_providers: 0,
  total_gpu_cores: 0,
  total_cpu_cores: 0,
  total_memory_gb: 0,
  total_bandwidth_gbs: 0,
  network_capacity_tps: 0,
  providers: [],
  models: [],
  provider_locations: [],
  provider_regions: [],
  request_locations: [
    {
      key: "is-reykjavik",
      scope: "city",
      city: "Reykjavik",
      country_code: "IS",
      latitude: 80,
      longitude: -22,
      requests: 10,
      prompt_tokens: 20,
      completion_tokens: 10,
      providers: 1,
    },
  ],
  request_regions: [],
  time_series: [],
};

describe("Request Geography", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("places a top-edge bubble tooltip below its marker", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (String(input).startsWith("/api/stats")) {
          return new Response(JSON.stringify(stats), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(null, { status: 404 });
      }),
    );

    render(<StatsPage />);

    const tooltipContent = (await screen.findAllByText("Reykjavik, IS"))[0];
    expect(tooltipContent.parentElement?.parentElement).toHaveClass("top-full");
  });
});
