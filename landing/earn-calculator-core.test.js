"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("./earn-calculator-core.js");

function marketFixture() {
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
        work_payout_micro_usd: 100_000_000,
        paid_tokens: 1_000_000,
        paid_jobs: 10,
        aggregate_tps: 300,
        aggregate_memory_bandwidth_gbps: 1_200,
        benchmark_tps: 100,
        benchmark_memory_bandwidth_gbps: 400,
        provider_supply: 3,
        estimate_available: true,
      },
    ],
    audit: {
      total_settled_work_micro_usd: 100_000_000,
      modeled_work_micro_usd: 100_000_000,
      unattributed_work_micro_usd: 0,
      total_paid_tokens: 1_000_000,
      modeled_paid_tokens: 1_000_000,
      unattributed_paid_tokens: 0,
      total_paid_jobs: 10,
      modeled_paid_jobs: 10,
      unattributed_paid_jobs: 0,
    },
    base_rewards: {
      enabled: true,
      monthly_pool_micro_usd: 9_000_000_000,
      min_uptime_fraction: 0.9,
      tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
    },
  };
}

test("candidate and existing capacity shares conserve the settled pool", function () {
  const payout = Core.conservedCandidatePayout(100, 300, 100);
  assert.deepEqual(payout, { candidate: 25, existing: 75, share: 0.25 });
  assert.ok(payout.candidate + payout.existing <= 100);
});

test("empty and inconsistent market responses are rejected", function () {
  const empty = marketFixture();
  empty.models = [];
  assert.throws(function () {
    Core.parseMarket(empty);
  }, /Invalid earnings market response/);

  const inconsistent = marketFixture();
  inconsistent.audit.modeled_work_micro_usd = 99_000_000;
  assert.throws(function () {
    Core.parseMarket(inconsistent);
  }, /Invalid earnings market response/);
});

test("a missing observed supply benchmark makes the model unavailable", function () {
  const market = marketFixture();
  market.models[0].benchmark_tps = 0;
  market.models[0].benchmark_memory_bandwidth_gbps = 0;
  market.models[0].estimate_available = false;
  market.models[0].unavailable_reason = "throughput_benchmark_unavailable";
  const parsed = Core.parseMarket(market);
  const rows = Core.buildModelRows(
    parsed,
    { bandwidthGBs: 400, idleWatts: 20, inferWatts: 50 },
    48,
    0.15,
  );
  assert.equal(rows[0].estimate, null);
  assert.equal(
    Core.unavailableReasonLabel(rows[0].model.unavailable_reason),
    "Supply benchmark unavailable",
  );
});

test("electricity includes full-month idle draw and realized workload draw", function () {
  const market = Core.parseMarket(marketFixture());
  const estimate = Core.calculateModelEstimate(
    market.models[0],
    { bandwidthGBs: 400, idleWatts: 20, inferWatts: 50 },
    48,
    market.base_rewards,
    0.15,
  );
  assert.ok(estimate);
  assert.equal(estimate.idleElectricityUSD, 2.16);
  assert.ok(estimate.workloadElectricityUSD > 0);
  assert.ok(
    Math.abs(
      estimate.workPayoutUSD +
        estimate.existingCapacityPayoutUSD -
        estimate.workPoolUSD,
    ) < 1e-12,
  );
});
