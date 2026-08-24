import { describe, expect, it } from "vitest";
import { parseEarningsMarket } from "@/lib/api/earnings-market";

function validMarket() {
  return {
    window_start: "2026-07-25T12:00:00Z",
    window_end: "2026-08-24T12:00:00Z",
    window_days: 30,
    models: [
      {
        id: "model",
        display_name: "Model",
        min_ram_gb: 24,
        size_bytes: 12_000_000_000,
        size_gb: 12,
        work_payout_micro_usd: 10_000_000,
        paid_tokens: 1_000,
        paid_jobs: 1,
        aggregate_tps: 100,
        aggregate_memory_bandwidth_gbps: 400,
        benchmark_tps: 50,
        benchmark_memory_bandwidth_gbps: 200,
        provider_supply: 1,
        estimate_available: true,
      },
    ],
    audit: {
      total_settled_work_micro_usd: 12_000_000,
      modeled_work_micro_usd: 10_000_000,
      unattributed_work_micro_usd: 2_000_000,
      total_paid_tokens: 1_200,
      modeled_paid_tokens: 1_000,
      unattributed_paid_tokens: 200,
      total_paid_jobs: 2,
      modeled_paid_jobs: 1,
      unattributed_paid_jobs: 1,
    },
    base_rewards: {
      enabled: true,
      monthly_pool_micro_usd: 9_000_000_000,
      min_uptime_fraction: 0.9,
      tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
    },
  };
}

describe("parseEarningsMarket", () => {
  it("accepts a reconciled calculator-ready response", () => {
    expect(parseEarningsMarket(validMarket()).models[0].id).toBe("model");
  });

  it("rejects an empty model response instead of enabling a fabricated fallback", () => {
    const payload = validMarket();
    payload.models = [];
    expect(() => parseEarningsMarket(payload)).toThrow("Invalid earnings market response");
  });

  it("rejects an unreconciled or internally inconsistent response", () => {
    const unreconciled = validMarket();
    unreconciled.audit.modeled_work_micro_usd = 9_000_000;
    expect(() => parseEarningsMarket(unreconciled)).toThrow("Invalid earnings market response");

    const unavailable = validMarket();
    unavailable.models[0].estimate_available = false;
    expect(() => parseEarningsMarket(unavailable)).toThrow("Invalid earnings market response");
  });
});
