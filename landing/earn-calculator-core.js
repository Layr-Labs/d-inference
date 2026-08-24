(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.DarkbloomEarnings = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const MONTH_HOURS = 30 * 24;
  const WINDOW_MS = 30 * 24 * 60 * 60 * 1000;
  const UNAVAILABLE_REASONS = new Set([
    "settled_work_unavailable",
    "competing_capacity_unavailable",
    "throughput_benchmark_unavailable",
  ]);

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function isNonNegativeNumber(value) {
    return typeof value === "number" && Number.isFinite(value) && value >= 0;
  }

  function isNonNegativeInteger(value) {
    return isNonNegativeNumber(value) && Number.isSafeInteger(value);
  }

  function expectedUnavailableReason(model) {
    if (
      model.work_payout_micro_usd <= 0 ||
      model.paid_tokens <= 0 ||
      model.paid_jobs <= 0
    ) {
      return "settled_work_unavailable";
    }
    if (model.aggregate_tps <= 0 || model.provider_supply <= 0) {
      return "competing_capacity_unavailable";
    }
    if (
      model.benchmark_tps <= 0 ||
      model.benchmark_memory_bandwidth_gbps <= 0
    ) {
      return "throughput_benchmark_unavailable";
    }
    return null;
  }

  function validModel(model) {
    if (
      !isObject(model) ||
      typeof model.id !== "string" ||
      !model.id ||
      typeof model.display_name !== "string" ||
      !model.display_name ||
      !Number.isSafeInteger(model.min_ram_gb) ||
      model.min_ram_gb <= 0 ||
      !Number.isSafeInteger(model.size_bytes) ||
      model.size_bytes <= 0 ||
      !isNonNegativeNumber(model.size_gb) ||
      model.size_gb <= 0 ||
      !isNonNegativeInteger(model.work_payout_micro_usd) ||
      !isNonNegativeInteger(model.paid_tokens) ||
      !isNonNegativeInteger(model.paid_jobs) ||
      !isNonNegativeNumber(model.aggregate_tps) ||
      !isNonNegativeNumber(model.aggregate_memory_bandwidth_gbps) ||
      !isNonNegativeNumber(model.benchmark_tps) ||
      !isNonNegativeNumber(model.benchmark_memory_bandwidth_gbps) ||
      !isNonNegativeInteger(model.provider_supply) ||
      typeof model.estimate_available !== "boolean"
    ) {
      return false;
    }
    const expected = expectedUnavailableReason(model);
    return model.estimate_available
      ? expected === null && model.unavailable_reason === undefined
      : expected !== null &&
          UNAVAILABLE_REASONS.has(model.unavailable_reason) &&
          model.unavailable_reason === expected;
  }

  function validAudit(audit) {
    if (!isObject(audit)) return false;
    const keys = [
      "total_settled_work_micro_usd",
      "modeled_work_micro_usd",
      "unattributed_work_micro_usd",
      "total_paid_tokens",
      "modeled_paid_tokens",
      "unattributed_paid_tokens",
      "total_paid_jobs",
      "modeled_paid_jobs",
      "unattributed_paid_jobs",
    ];
    return (
      keys.every(function (key) {
        return isNonNegativeInteger(audit[key]);
      }) &&
      audit.modeled_work_micro_usd + audit.unattributed_work_micro_usd ===
        audit.total_settled_work_micro_usd &&
      audit.modeled_paid_tokens + audit.unattributed_paid_tokens ===
        audit.total_paid_tokens &&
      audit.modeled_paid_jobs + audit.unattributed_paid_jobs ===
        audit.total_paid_jobs
    );
  }

  function validBaseRewards(policy) {
    if (
      !isObject(policy) ||
      typeof policy.enabled !== "boolean" ||
      !isNonNegativeInteger(policy.monthly_pool_micro_usd) ||
      !isNonNegativeNumber(policy.min_uptime_fraction) ||
      policy.min_uptime_fraction > 1 ||
      !isNonNegativeNumber(policy.reduction_k) ||
      !isNonNegativeNumber(policy.account_cap_fraction) ||
      policy.account_cap_fraction > 1 ||
      !Array.isArray(policy.tiers) ||
      !policy.tiers.length
    ) {
      return false;
    }
    const seen = new Set();
    return policy.tiers.every(function (tier) {
      if (
        !isObject(tier) ||
        !Number.isSafeInteger(tier.min_ram_gb) ||
        tier.min_ram_gb <= 0 ||
        !isNonNegativeInteger(tier.monthly_micro_usd) ||
        seen.has(tier.min_ram_gb)
      ) {
        return false;
      }
      seen.add(tier.min_ram_gb);
      return true;
    });
  }

  function parseMarket(value) {
    const start = isObject(value) ? Date.parse(value.window_start) : NaN;
    const end = isObject(value) ? Date.parse(value.window_end) : NaN;
    if (
      !isObject(value) ||
      value.window_days !== 30 ||
      !Number.isFinite(start) ||
      !Number.isFinite(end) ||
      end - start !== WINDOW_MS ||
      !Array.isArray(value.models) ||
      !value.models.length ||
      !value.models.every(validModel) ||
      !validAudit(value.audit) ||
      !validBaseRewards(value.base_rewards)
    ) {
      throw new Error("Invalid earnings market response");
    }
    if (new Set(value.models.map(function (model) { return model.id; })).size !== value.models.length) {
      throw new Error("Invalid earnings market response");
    }
    const modeledWork = value.models.reduce(function (sum, model) {
      return sum + model.work_payout_micro_usd;
    }, 0);
    const modeledTokens = value.models.reduce(function (sum, model) {
      return sum + model.paid_tokens;
    }, 0);
    const modeledJobs = value.models.reduce(function (sum, model) {
      return sum + model.paid_jobs;
    }, 0);
    if (
      modeledWork !== value.audit.modeled_work_micro_usd ||
      modeledTokens !== value.audit.modeled_paid_tokens ||
      modeledJobs !== value.audit.modeled_paid_jobs
    ) {
      throw new Error("Invalid earnings market response");
    }
    return value;
  }

  function candidateCapacityTPS(model, candidateBandwidthGBs) {
    if (
      !Number.isFinite(candidateBandwidthGBs) ||
      candidateBandwidthGBs <= 0 ||
      model.benchmark_tps <= 0 ||
      model.benchmark_memory_bandwidth_gbps <= 0
    ) {
      return null;
    }
    const candidate =
      (model.benchmark_tps / model.benchmark_memory_bandwidth_gbps) *
      candidateBandwidthGBs;
    return Number.isFinite(candidate) && candidate > 0 ? candidate : null;
  }

  function conservedCandidatePayout(poolUSD, existingCapacityTPS, candidateTPS) {
    if (
      !Number.isFinite(poolUSD) ||
      !Number.isFinite(existingCapacityTPS) ||
      !Number.isFinite(candidateTPS) ||
      poolUSD < 0 ||
      existingCapacityTPS <= 0 ||
      candidateTPS <= 0
    ) {
      return null;
    }
    const denominator = existingCapacityTPS + candidateTPS;
    const share = candidateTPS / denominator;
    const candidate = poolUSD * share;
    return {
      candidate: candidate,
      // Keep the represented shares at or below the fixed pool despite
      // floating-point rounding.
      existing: poolUSD - candidate,
      share: share,
    };
  }

  function baseRewardPotentialUSD(policy, memoryGB, workPayoutUSD) {
    if (workPayoutUSD === undefined) workPayoutUSD = 0;
    if (
      !policy.enabled ||
      !Number.isFinite(memoryGB) ||
      !Number.isFinite(workPayoutUSD) ||
      !Number.isFinite(policy.reduction_k) ||
      !Number.isFinite(policy.account_cap_fraction) ||
      memoryGB < 0 ||
      workPayoutUSD < 0 ||
      policy.reduction_k < 0 ||
      policy.account_cap_fraction < 0 ||
      policy.account_cap_fraction > 1
    ) {
      return 0;
    }
    let selected = 0;
    let selectedMinRAM = -1;
    policy.tiers.forEach(function (tier) {
      if (memoryGB >= tier.min_ram_gb && tier.min_ram_gb > selectedMinRAM) {
        selected = tier.monthly_micro_usd / 1e6;
        selectedMinRAM = tier.min_ram_gb;
      }
    });
    const poolUSD = policy.monthly_pool_micro_usd / 1e6;
    const reduced = Math.max(0, selected - policy.reduction_k * workPayoutUSD);
    const accountCap =
      policy.account_cap_fraction > 0
        ? poolUSD * policy.account_cap_fraction
        : poolUSD;
    return Math.min(reduced, poolUSD, accountCap);
  }

  function calculateModelEstimate(model, hardware, memoryGB, baseRewards, electricityCostPerKWh) {
    if (
      memoryGB < model.min_ram_gb ||
      !model.estimate_available ||
      model.work_payout_micro_usd <= 0 ||
      model.paid_tokens <= 0 ||
      model.paid_jobs <= 0 ||
      model.aggregate_tps <= 0 ||
      model.provider_supply <= 0 ||
      !Number.isFinite(hardware.idleWatts) ||
      !Number.isFinite(hardware.inferWatts) ||
      !Number.isFinite(electricityCostPerKWh) ||
      hardware.idleWatts < 0 ||
      hardware.inferWatts < 0 ||
      electricityCostPerKWh < 0
    ) {
      return null;
    }
    const candidateTPS = candidateCapacityTPS(model, hardware.bandwidthGBs);
    if (candidateTPS === null) return null;
    const workPoolUSD = model.work_payout_micro_usd / 1e6;
    const payout = conservedCandidatePayout(workPoolUSD, model.aggregate_tps, candidateTPS);
    if (!payout) return null;

    const allocatedTokens = model.paid_tokens * payout.share;
    const activeHours = Math.min(MONTH_HOURS, allocatedTokens / candidateTPS / 3600);
    const idleElectricityUSD =
      (hardware.idleWatts / 1000) * MONTH_HOURS * electricityCostPerKWh;
    const workloadElectricityUSD =
      (Math.max(0, hardware.inferWatts - hardware.idleWatts) / 1000) *
      activeHours *
      electricityCostPerKWh;
    const electricityUSD = idleElectricityUSD + workloadElectricityUSD;
    const baseReward = baseRewardPotentialUSD(baseRewards, memoryGB, payout.candidate);
    const monthlyNetUSD = payout.candidate + baseReward - electricityUSD;
    return {
      model: model,
      candidateTPS: candidateTPS,
      candidateShare: payout.share,
      workPoolUSD: workPoolUSD,
      workPayoutUSD: payout.candidate,
      existingCapacityPayoutUSD: payout.existing,
      allocatedTokens: allocatedTokens,
      activeHours: activeHours,
      idleElectricityUSD: idleElectricityUSD,
      workloadElectricityUSD: workloadElectricityUSD,
      electricityUSD: electricityUSD,
      baseRewardPotentialUSD: baseReward,
      monthlyNetUSD: monthlyNetUSD,
      annualNetUSD: monthlyNetUSD * 12,
    };
  }

  function buildModelRows(market, hardware, memoryGB, electricityCostPerKWh) {
    const rows = market.models.map(function (model) {
      const fits = model.min_ram_gb <= memoryGB;
      return {
        model: model,
        fits: fits,
        estimate: fits
          ? calculateModelEstimate(
              model,
              hardware,
              memoryGB,
              market.base_rewards,
              electricityCostPerKWh,
            )
          : null,
      };
    });
    rows.sort(function (a, b) {
      if (a.fits !== b.fits) return a.fits ? -1 : 1;
      if (a.fits && b.fits) {
        if (Boolean(a.estimate) !== Boolean(b.estimate)) return a.estimate ? -1 : 1;
        const netDelta =
          (b.estimate ? b.estimate.monthlyNetUSD : 0) -
          (a.estimate ? a.estimate.monthlyNetUSD : 0);
        if (netDelta !== 0) return netDelta;
      }
      if (a.model.min_ram_gb !== b.model.min_ram_gb) {
        return a.model.min_ram_gb - b.model.min_ram_gb;
      }
      return a.model.id.localeCompare(b.model.id);
    });
    return rows;
  }

  function unavailableReasonLabel(reason) {
    switch (reason) {
      case "settled_work_unavailable":
        return "Settled payout data unavailable";
      case "competing_capacity_unavailable":
        return "Competing capacity unavailable";
      case "throughput_benchmark_unavailable":
        return "Supply benchmark unavailable";
      default:
        return "Estimate unavailable";
    }
  }

  return {
    MONTH_HOURS: MONTH_HOURS,
    parseMarket: parseMarket,
    candidateCapacityTPS: candidateCapacityTPS,
    conservedCandidatePayout: conservedCandidatePayout,
    baseRewardPotentialUSD: baseRewardPotentialUSD,
    calculateModelEstimate: calculateModelEstimate,
    buildModelRows: buildModelRows,
    unavailableReasonLabel: unavailableReasonLabel,
  };
});
