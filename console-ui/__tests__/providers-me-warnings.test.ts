import { describe, it, expect } from "vitest";
import {
  computeWarnings,
  highestSeverity,
  semverLess,
} from "@/app/providers/me/warnings";
import type { MyProvider, MyProvidersResponse } from "@/app/providers/me/types";

const ctx: Pick<
  MyProvidersResponse,
  "latest_provider_version" | "min_provider_version" | "heartbeat_timeout_seconds" | "challenge_max_age_seconds"
> = {
  latest_provider_version: "0.3.10",
  min_provider_version: "0.3.10",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

function baseProvider(overrides: Partial<MyProvider> = {}): MyProvider {
  return {
    id: "p1",
    account_id: "acct-1",
    status: "online",
    online: true,
    hardware: { chip_name: "Apple M3 Max", memory_gb: 64 },
    models: [{ id: "mlx-community/Qwen3.5-9B-MLX-4bit" }],
    trust_level: "hardware",
    attested: true,
    mda_verified: true,
    acme_verified: true,
    se_key_bound: true,
    secure_enclave: true,
    sip_enabled: true,
    secure_boot_enabled: true,
    authenticated_root_enabled: true,
    runtime_verified: true,
    failed_challenges: 0,
    pending_requests: 0,
    max_concurrency: 8,
    reputation: {
      score: 0.85,
      total_jobs: 0,
      successful_jobs: 0,
      failed_jobs: 0,
      total_uptime_seconds: 0,
      avg_response_time_ms: 0,
      challenges_passed: 5,
      challenges_failed: 0,
    },
    lifetime_requests_served: 0,
    lifetime_tokens_generated: 0,
    earnings_total_micro_usd: 0,
    earnings_count: 0,
    last_challenge_verified: new Date().toISOString(),
    version: "0.3.10",
    ...overrides,
  };
}

describe("semverLess", () => {
  it("compares numeric segments", () => {
    expect(semverLess("0.3.9", "0.3.10")).toBe(true);
    expect(semverLess("0.3.10", "0.3.9")).toBe(false);
    expect(semverLess("0.3.10", "0.3.10")).toBe(false);
    expect(semverLess("0.4.0", "0.3.99")).toBe(false);
  });
  it("treats empty version as falsy", () => {
    expect(semverLess("", "0.3.10")).toBe(true);
    expect(semverLess("0.3.10", "")).toBe(false);
    expect(semverLess("", "")).toBe(false);
  });
});

describe("computeWarnings", () => {
  it("returns no warnings for a perfectly healthy machine", () => {
    const warnings = computeWarnings(baseProvider(), ctx);
    expect(warnings).toEqual([]);
  });

  it("flags offline machines as blocking", () => {
    const warnings = computeWarnings(baseProvider({ status: "offline", online: false }), ctx);
    expect(warnings.find((w) => w.id === "offline")?.severity).toBe("blocking");
  });

  it("flags untrusted as blocking and explains failed challenges", () => {
    const warnings = computeWarnings(
      baseProvider({ status: "untrusted", failed_challenges: 3 }),
      ctx
    );
    expect(warnings.find((w) => w.id === "untrusted")?.severity).toBe("blocking");
  });

  it("flags runtime mismatch as blocking", () => {
    const warnings = computeWarnings(baseProvider({ runtime_verified: false }), ctx);
    expect(warnings.find((w) => w.id === "runtime_unverified")?.severity).toBe("blocking");
  });

  it("flags version below min as blocking", () => {
    const warnings = computeWarnings(
      baseProvider({ version: "0.3.5" }),
      { ...ctx, min_provider_version: "0.3.10" }
    );
    expect(warnings.find((w) => w.id === "version_below_min")?.severity).toBe("blocking");
  });

  it("flags self-signed trust as blocking (production min trust = hardware)", () => {
    const warnings = computeWarnings(baseProvider({ trust_level: "self_signed" }), ctx);
    expect(warnings.find((w) => w.id === "trust_self_signed")?.severity).toBe("blocking");
  });

  it("flags trust_level=none as blocking", () => {
    const warnings = computeWarnings(baseProvider({ trust_level: "none", mda_verified: false }), ctx);
    expect(warnings.find((w) => w.id === "trust_none")?.severity).toBe("blocking");
  });

  it("flags hardware trust without MDA as degrading", () => {
    const warnings = computeWarnings(baseProvider({ mda_verified: false }), ctx);
    expect(warnings.find((w) => w.id === "mda_missing")?.severity).toBe("degrading");
  });

  it("flags critical thermal as blocking", () => {
    const warnings = computeWarnings(
      baseProvider({
        system_metrics: { memory_pressure: 0.2, cpu_usage: 0.1, thermal_state: "critical" },
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "thermal_critical")?.severity).toBe("blocking");
  });

  it("flags serious thermal as degrading, fair as degrading", () => {
    const serious = computeWarnings(
      baseProvider({
        system_metrics: { memory_pressure: 0.2, cpu_usage: 0.1, thermal_state: "serious" },
      }),
      ctx
    );
    expect(serious.find((w) => w.id === "thermal_serious")?.severity).toBe("degrading");

    const fair = computeWarnings(
      baseProvider({
        system_metrics: { memory_pressure: 0.2, cpu_usage: 0.1, thermal_state: "fair" },
      }),
      ctx
    );
    expect(fair.find((w) => w.id === "thermal_fair")?.severity).toBe("degrading");
  });

  it("flags >90% memory pressure", () => {
    const warnings = computeWarnings(
      baseProvider({
        system_metrics: { memory_pressure: 0.95, cpu_usage: 0.1, thermal_state: "nominal" },
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "memory_pressure_high")?.severity).toBe("degrading");
  });

  it("flags crashed backend slot as degrading (scoring penalty, not exclusion)", () => {
    const warnings = computeWarnings(
      baseProvider({
        backend_capacity: {
          slots: [
            {
              model: "model-a",
              state: "crashed",
              num_running: 0,
              num_waiting: 0,
              active_tokens: 0,
              max_tokens_potential: 0,
            },
          ],
          gpu_memory_active_gb: 0,
          gpu_memory_peak_gb: 0,
          gpu_memory_cache_gb: 0,
          total_memory_gb: 64,
        },
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "backend_crashed")?.severity).toBe("degrading");
  });

  it("flags stale challenge (>6 min) as blocking", () => {
    const elevenMinAgo = new Date(Date.now() - 11 * 60 * 1000).toISOString();
    const warnings = computeWarnings(
      baseProvider({ last_challenge_verified: elevenMinAgo }),
      ctx
    );
    expect(warnings.find((w) => w.id === "challenge_stale")?.severity).toBe("blocking");
  });

  it("does NOT flag a fresh challenge as stale", () => {
    const oneMinAgo = new Date(Date.now() - 60 * 1000).toISOString();
    const warnings = computeWarnings(
      baseProvider({ last_challenge_verified: oneMinAgo }),
      ctx
    );
    expect(warnings.find((w) => w.id === "challenge_stale")).toBeUndefined();
  });

  it("flags zero catalog models as blocking when machine is online", () => {
    const warnings = computeWarnings(baseProvider({ models: [] }), ctx);
    expect(warnings.find((w) => w.id === "no_catalog_models")?.severity).toBe("blocking");
  });

  it("does not flag no-models for an offline machine", () => {
    const warnings = computeWarnings(
      baseProvider({ models: [], status: "offline", online: false }),
      ctx
    );
    expect(warnings.find((w) => w.id === "no_catalog_models")).toBeUndefined();
  });

  it("flags idle_shutdown backend as degrading", () => {
    const warnings = computeWarnings(
      baseProvider({
        backend_capacity: {
          slots: [
            {
              model: "model-a",
              state: "idle_shutdown",
              num_running: 0,
              num_waiting: 0,
              active_tokens: 0,
              max_tokens_potential: 0,
            },
          ],
          gpu_memory_active_gb: 0,
          gpu_memory_peak_gb: 0,
          gpu_memory_cache_gb: 0,
          total_memory_gb: 64,
        },
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "backend_idle_shutdown")?.severity).toBe("degrading");
  });

  it("flags low success rate (degrading)", () => {
    const warnings = computeWarnings(
      baseProvider({
        reputation: {
          score: 0.3,
          total_jobs: 20,
          successful_jobs: 10,
          failed_jobs: 10,
          total_uptime_seconds: 100,
          avg_response_time_ms: 500,
          challenges_passed: 5,
          challenges_failed: 0,
        },
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "low_success_rate")?.severity).toBe("degrading");
  });

  it("does NOT flag low success rate when sample size is small", () => {
    const warnings = computeWarnings(
      baseProvider({
        reputation: {
          score: 0.3,
          total_jobs: 3,
          successful_jobs: 1,
          failed_jobs: 2,
          total_uptime_seconds: 100,
          avg_response_time_ms: 500,
          challenges_passed: 5,
          challenges_failed: 0,
        },
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "low_success_rate")).toBeUndefined();
  });

  it("flags no payout configured (info)", () => {
    const warnings = computeWarnings(
      baseProvider({ account_id: "", wallet_address: undefined }),
      ctx
    );
    expect(warnings.find((w) => w.id === "no_payout")?.severity).toBe("info");
  });

  it("flags outdated version when latest is newer (info)", () => {
    const warnings = computeWarnings(
      baseProvider({ version: "0.3.9" }),
      { ...ctx, latest_provider_version: "0.3.10", min_provider_version: "0.3.5" }
    );
    expect(warnings.find((w) => w.id === "outdated_version")?.severity).toBe("info");
  });

  it("does NOT double-warn outdated when version is also below the min", () => {
    const warnings = computeWarnings(
      baseProvider({ version: "0.3.5" }),
      { ...ctx, latest_provider_version: "0.3.10", min_provider_version: "0.3.10" }
    );
    expect(warnings.find((w) => w.id === "version_below_min")).toBeDefined();
    expect(warnings.find((w) => w.id === "outdated_version")).toBeUndefined();
  });

  it("flags missing first challenge (info) when otherwise eligible", () => {
    const warnings = computeWarnings(
      baseProvider({ last_challenge_verified: undefined }),
      ctx
    );
    expect(warnings.find((w) => w.id === "no_challenge_yet")?.severity).toBe("info");
  });

  it("does not surface trust warnings for offline machines (offline takes precedence)", () => {
    const warnings = computeWarnings(
      baseProvider({
        status: "offline",
        online: false,
        trust_level: "self_signed",
      }),
      ctx
    );
    expect(warnings.find((w) => w.id === "trust_self_signed")).toBeUndefined();
    expect(warnings.find((w) => w.id === "offline")).toBeDefined();
  });
});

describe("highestSeverity", () => {
  it("returns blocking when present", () => {
    expect(
      highestSeverity([
        { id: "a", severity: "info", title: "", detail: "" },
        { id: "b", severity: "blocking", title: "", detail: "" },
      ])
    ).toBe("blocking");
  });
  it("returns degrading when no blocking", () => {
    expect(
      highestSeverity([
        { id: "a", severity: "info", title: "", detail: "" },
        { id: "b", severity: "degrading", title: "", detail: "" },
      ])
    ).toBe("degrading");
  });
  it("returns null on empty", () => {
    expect(highestSeverity([])).toBeNull();
  });
});
