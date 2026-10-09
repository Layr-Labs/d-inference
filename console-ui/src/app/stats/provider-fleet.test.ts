import { describe, expect, it } from "vitest";
import {
  isProviderRoutable,
  passesPublishedVerificationChecks,
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
  it("separates published ready verdicts from nodes actively serving", () => {
    expect(providerRouteState(provider({ routable: true }))).toBe("ready");
    expect(providerRouteState(provider({ routable: true, status: "serving" }))).toBe("serving");
  });

  it("keeps missing routing verdicts unknown even when public checks pass", () => {
    expect(passesPublishedVerificationChecks(provider(), NOW)).toBe(true);
    expect(isProviderRoutable(provider())).toBe(false);
    expect(providerRouteState(provider())).toBe("unreported");
    expect(providerRouteReason(provider(), NOW)).toContain("Routing eligibility is not published");
  });

  it("keeps stale and missing challenges out of the published verification subset", () => {
    const stale = provider({ last_challenge_verified: "2026-07-13T01:13:00Z" });
    expect(passesPublishedVerificationChecks(stale, NOW)).toBe(false);
    expect(passesPublishedVerificationChecks(provider({ last_challenge_verified: undefined }), NOW)).toBe(false);
    expect(providerRouteState(stale)).toBe("unreported");
    expect(providerRouteReason(stale, NOW)).toContain("outside the sixteen-minute verification window");
  });

  it("keeps delayed challenges verified through sixteen minutes without inferring routing", () => {
    const delayed = provider({ last_challenge_verified: "2026-07-13T01:15:00Z" });
    expect(passesPublishedVerificationChecks(delayed, NOW)).toBe(true);
    expect(isProviderRoutable(delayed)).toBe(false);
  });

  it("requires a published successful runtime check for verification", () => {
    expect(passesPublishedVerificationChecks(provider({ runtime_verified: undefined }), NOW)).toBe(false);
  });

  it("uses the coordinator routable verdict when published, independently of partial public fields", () => {
    expect(isProviderRoutable(provider({ routable: false }))).toBe(false);
    expect(providerRouteState(provider({ routable: false }))).toBe("attention");
    expect(isProviderRoutable(provider({ trust_level: "self_signed", routable: true }))).toBe(true);
    expect(providerRouteReason(provider({ routable: false }), NOW)).toContain("excluded from public routing");
  });

  it("treats every non-hardware identity as basic trust", () => {
    const selfSigned = provider({ trust_level: "self_signed" });
    expect(matchesTrustFilter(selfSigned, "basic")).toBe(true);
    expect(matchesTrustFilter(selfSigned, "hardware")).toBe(false);
  });

  it("summarizes observed serving, hardware trust, and routing verdicts separately", () => {
    const summary = summarizeProviderFleet([
      provider({ routable: true }),
      provider({ id: "node-2", status: "serving" }),
      provider({ id: "node-3", trust_level: "self_signed", routable: false }),
    ]);
    expect(summary).toEqual({ visible: 3, ready: 1, serving: 1, attention: 1, unreported: 1, hardware: 2 });
  });
});
