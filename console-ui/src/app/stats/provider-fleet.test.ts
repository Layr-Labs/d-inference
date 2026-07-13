import { describe, expect, it } from "vitest";
import {
  isProviderRoutable,
  matchesTrustFilter,
  providerRouteReason,
  providerRouteState,
  summarizeProviderFleet,
  type ProviderStats,
} from "./provider-fleet";

const NOW = Date.parse("2026-07-13T01:30:00Z");

function provider(overrides: Partial<ProviderStats> = {}): ProviderStats {
  return {
    id: "node-1",
    chip: "Apple M3 Ultra",
    chip_family: "M3",
    chip_tier: "Ultra",
    machine_model: "Mac15,14",
    memory_gb: 512,
    gpu_cores: 80,
    cpu_cores: { total: 32, performance: 24, efficiency: 8 },
    memory_bandwidth_gbs: 819,
    status: "online",
    trust_level: "hardware",
    decode_tps: 80,
    requests_served: 10,
    tokens_generated: 100,
    runtime_verified: true,
    last_challenge_verified: "2026-07-13T01:27:00Z",
    ...overrides,
  };
}

describe("provider routing presentation", () => {
  it("separates ready nodes from nodes actively serving", () => {
    expect(providerRouteState(provider(), NOW)).toBe("ready");
    expect(providerRouteState(provider({ status: "serving" }), NOW)).toBe("serving");
  });

  it("treats stale and missing challenges as attention states", () => {
    const stale = provider({ last_challenge_verified: "2026-07-13T01:20:00Z" });
    expect(isProviderRoutable(stale, NOW)).toBe(false);
    expect(providerRouteState(stale, NOW)).toBe("attention");
    expect(providerRouteReason(stale, NOW)).toContain("older than six minutes");
  });

  it("uses the coordinator routable verdict when it is published", () => {
    expect(isProviderRoutable(provider({ routable: false }), NOW)).toBe(false);
    expect(isProviderRoutable(provider({ trust_level: "self_signed", routable: true }), NOW)).toBe(true);
  });

  it("treats every non-hardware identity as basic trust", () => {
    const selfSigned = provider({ trust_level: "self_signed" });
    expect(matchesTrustFilter(selfSigned, "basic")).toBe(true);
    expect(matchesTrustFilter(selfSigned, "hardware")).toBe(false);
  });

  it("summarizes each readiness state independently", () => {
    const summary = summarizeProviderFleet([
      provider(),
      provider({ id: "node-2", status: "serving" }),
      provider({ id: "node-3", trust_level: "self_signed" }),
    ], NOW);
    expect(summary).toEqual({ visible: 3, ready: 1, serving: 1, attention: 1 });
  });
});
