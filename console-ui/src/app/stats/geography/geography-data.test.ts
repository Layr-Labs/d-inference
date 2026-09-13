import { describe, expect, it } from "vitest";
import type { PlatformStats, ProviderLocationBucket, RequestLocationBucket } from "../platform-types";
import { buildGeographyData } from "./geography-data";

const base: PlatformStats = {
  total_requests: 0, total_prompt_tokens: 0, total_completion_tokens: 0, total_tokens: 0,
  avg_tokens_per_request: 0, active_providers: 0, total_gpu_cores: 0, total_cpu_cores: 0,
  total_memory_gb: 0, total_bandwidth_gbs: 0, network_capacity_tps: 0,
  providers: [], models: [], time_series: [],
};
const provider = (overrides: Partial<ProviderLocationBucket> = {}): ProviderLocationBucket => ({
  key: "us", scope: "region", region: "California", country: "United States", country_code: "US",
  latitude: 38, longitude: -122, providers: 3, hardware_attested: 2, gpu_cores: 60, memory_gb: 96,
  ...overrides,
});
const request = (overrides: Partial<RequestLocationBucket> = {}): RequestLocationBucket => ({
  ...provider(), requests: 12, prompt_tokens: 30, completion_tokens: 20, ...overrides,
});

describe("geography data", () => {
  it("preserves distinct regions when backend keys collide", () => {
    const result = buildGeographyData({ ...base, provider_regions: [provider(), provider({ region: "Oregon", providers: 4 })] }, "providers");
    expect(result.total).toBe(7);
    expect(result.countries).toBe(1);
    expect(new Set(result.markers.map((marker) => marker.key)).size).toBe(2);
    expect(result.regions.map((place) => place.label)).toEqual(["Oregon", "California"]);
  });

  it("combines alternate display names under the same country and region codes without losing counts", () => {
    const result = buildGeographyData({
      ...base,
      provider_regions: [provider({ region_code: "CA" }), provider({ region_code: "CA", region: "Calif.", country: "USA", providers: 7, latitude: 36 })],
    }, "providers");
    expect(result.total).toBe(10);
    expect(result.regions).toHaveLength(1);
    expect(result.regions[0].latitude).toBeCloseTo(36.6);
  });

  it("uses region totals once and preserves suppression and unknown counts", () => {
    const result = buildGeographyData({
      ...base, provider_regions: [provider({ providers: 12 })],
      provider_locations: [provider({ scope: "city", city: "Berkeley", providers: 8 })],
      suppressed_city_location_providers: 4, unknown_location_providers: 3,
    }, "providers");
    expect(result.total).toBe(12);
    expect(result.markers[0].nodes).toBe(8);
    expect(result.unknown).toBe(3);
    expect(result.suppressed).toBe(4);
    expect(result.mapScope).toBe("city");
  });

  it("never promotes below-threshold city data, falling back to published regional locations", () => {
    const result = buildGeographyData({
      ...base, request_location_privacy_min_requests: 5,
      request_locations: [request({ scope: "city", city: "Small city", requests: 4 })],
      request_regions: [request({ requests: 12 })], location_window_hours: 24,
    }, "requests");
    expect(result.markers).toHaveLength(1);
    expect(result.markers[0].label).not.toContain("Small city");
    expect(result.total).toBe(12);
    expect(result.mapScope).toBe("region");
    expect(result.period).toBe("Last 24 hours");
  });

  it("does not plot unknown, invalid, or out-of-range coordinates", () => {
    const result = buildGeographyData({
      ...base,
      provider_regions: [
        provider({ region: "Missing", latitude: undefined, longitude: undefined }),
        provider({ region: "Sentinel", latitude: 0, longitude: 0 }),
        provider({ region: "Invalid", latitude: Number.NaN }),
        provider({ region: "Outside", longitude: 190 }),
        provider({ region: "Valid", latitude: 0, longitude: 12 }),
      ],
    }, "providers");
    expect(result.total).toBe(15);
    expect(result.markers).toHaveLength(1);
    expect(result.markers[0].label).toContain("Valid");
  });

  it("bounds map work without truncating totals", () => {
    const result = buildGeographyData({
      ...base,
      provider_regions: Array.from({ length: 250 }, (_, index) => provider({ region: `Region ${index}`, providers: index + 1 })),
    }, "providers");
    expect(result.markers).toHaveLength(120);
    expect(result.omittedPlaces).toBe(130);
    expect(result.total).toBe(31375);
    expect(result.markers[0].nodes).toBe(250);
    expect(result.regions).toHaveLength(250);
  });
});
