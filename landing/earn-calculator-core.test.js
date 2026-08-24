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
      reduction_k: 0,
      account_cap_fraction: 0,
      tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
    },
  };
}

test("candidate and existing capacity shares conserve the settled pool", function () {
  const payout = Core.conservedCandidatePayout(100, 300, 100);
  assert.deepEqual(payout, { candidate: 25, existing: 75, share: 0.25 });
  assert.ok(payout.candidate + payout.existing <= 100);
});

test("the reported M4 Max case stays near the realized per-provider run rate", function () {
  const market = marketFixture();
  const hardware = { bandwidthGBs: 546, idleWatts: 20, inferWatts: 50 };
  const candidateTPS = 0.25 * hardware.bandwidthGBs;
  Object.assign(market.models[0], {
    id: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
    display_name: "Qwen 3.6 35B A3B",
    work_payout_micro_usd: 481_450_000 * 30,
    paid_tokens: 1_000_000_000 * 30,
    paid_jobs: 10_000 * 30,
    aggregate_tps: candidateTPS * 787,
    aggregate_memory_bandwidth_gbps: hardware.bandwidthGBs * 787,
    benchmark_tps: candidateTPS,
    benchmark_memory_bandwidth_gbps: hardware.bandwidthGBs,
    provider_supply: 787,
  });
  Object.assign(market.audit, {
    total_settled_work_micro_usd: market.models[0].work_payout_micro_usd,
    modeled_work_micro_usd: market.models[0].work_payout_micro_usd,
    unattributed_work_micro_usd: 0,
    total_paid_tokens: market.models[0].paid_tokens,
    modeled_paid_tokens: market.models[0].paid_tokens,
    unattributed_paid_tokens: 0,
    total_paid_jobs: market.models[0].paid_jobs,
    modeled_paid_jobs: market.models[0].paid_jobs,
    unattributed_paid_jobs: 0,
  });

  const estimate = Core.calculateModelEstimate(
    Core.parseMarket(market).models[0],
    hardware,
    48,
    market.base_rewards,
    0.15,
  );

  assert.ok(estimate);
  assert.ok(Math.abs(estimate.candidateShare - 1 / 788) < 1e-12);
  assert.ok(Math.abs(estimate.workPayoutUSD - (481.45 * 30) / 788) < 1e-8);
  assert.ok(estimate.monthlyNetUSD < 40);
  assert.ok(estimate.annualNetUSD < 500);
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

test("base reward potential cannot exceed the configured fleet pool", function () {
  assert.equal(
    Core.baseRewardPotentialUSD(
      {
        enabled: true,
        monthly_pool_micro_usd: 5_000_000,
        min_uptime_fraction: 0.9,
        reduction_k: 0,
        account_cap_fraction: 0,
        tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
      },
      24,
    ),
    5,
  );
});

test("base reward potential applies work reduction and account caps", function () {
  const policy = {
    enabled: true,
    monthly_pool_micro_usd: 100_000_000,
    min_uptime_fraction: 0.9,
    reduction_k: 0.25,
    account_cap_fraction: 0,
    tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
  };
  assert.equal(Core.baseRewardPotentialUSD(policy, 24, 8), 8);
  assert.equal(
    Core.baseRewardPotentialUSD(
      Object.assign({}, policy, { account_cap_fraction: 0.05 }),
      24,
      8,
    ),
    5,
  );
});

test("model rows rank the highest estimated net rather than highest gross work", function () {
  const market = marketFixture();
  Object.assign(market.models[0], {
    id: "high-gross",
    display_name: "High gross",
    work_payout_micro_usd: 40_000_000,
    paid_tokens: 1_000_000_000_000,
    aggregate_tps: 100,
    aggregate_memory_bandwidth_gbps: 400,
    benchmark_tps: 100,
    benchmark_memory_bandwidth_gbps: 400,
    provider_supply: 1,
  });
  market.models.push(
    Object.assign({}, market.models[0], {
      id: "high-net",
      display_name: "High net",
      work_payout_micro_usd: 38_000_000,
      paid_tokens: 1,
    }),
  );

  const rows = Core.buildModelRows(
    market,
    { bandwidthGBs: 400, idleWatts: 20, inferWatts: 50 },
    48,
    0.15,
  );

  assert.equal(rows[0].model.id, "high-net");
  assert.ok(rows[0].estimate.workPayoutUSD < rows[1].estimate.workPayoutUSD);
  assert.ok(rows[0].estimate.monthlyNetUSD > rows[1].estimate.monthlyNetUSD);
});
