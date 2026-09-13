const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("./earn-calculator-core.js");

test("catalog pins the three supported models, active weights, and prices", () => {
  assert.deepEqual(Core.CALCULATOR_MODELS.map((model) => model.displayName), [
    "Qwen3.6 35B A3B",
    "Gemma 4 26B A4B",
    "GPT-OSS 20B",
  ]);
  assert.deepEqual(Core.CALCULATOR_MODELS.map((model) => model.activeParameterCount), [
    3_000_000_000,
    4_000_000_000,
    3_600_000_000,
  ]);
  assert.deepEqual(Core.CALCULATOR_MODELS.map((model) => model.outputPriceMicroUSDPerMillion), [
    700_000,
    220_000,
    69_000,
  ]);
});

test("projection uses 65% bandwidth, duty cycle, and no batching", () => {
  const model = Core.CALCULATOR_MODELS[0];
  const hardware = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  const estimate = Core.calculateCapacityRevenue(model, hardware, 48, 50);
  assert.ok(estimate);
  assert.equal(estimate.activeSecondsPerMonth, 360 * 60 * 60);
  assert.ok(Math.abs(estimate.activeWeightGBPerToken - (3 * 22) / 35) < 1e-12);
  assert.ok(
    Math.abs(
      estimate.decodeTokensPerSecond -
        (hardware.bandwidthGBs * 0.65) / ((3 * 22) / 35),
    ) < 1e-12,
  );
});

test("projection scales linearly with duty cycle", () => {
  const model = Core.CALCULATOR_MODELS[0];
  const hardware = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  const low = Core.calculateCapacityRevenue(model, hardware, 48, 25);
  const high = Core.calculateCapacityRevenue(model, hardware, 48, 50);
  assert.ok(Math.abs(high.monthlyRevenueUSD - low.monthlyRevenueUSD * 2) < 1e-12);
});

test("provider options exclude unsupported Mac families and require 48 GB", () => {
  assert.equal(Core.MIN_PROVIDER_MEMORY_GB, 48);
  assert.deepEqual(
    [...new Set(Core.PROVIDER_HARDWARE_OPTIONS.map((option) => option.macType))],
    ["MacBook Pro", "Mac Mini", "Mac Studio", "Mac Pro"],
  );
});

test("new M5 Ultra and M6 profiles are available", () => {
  assert.deepEqual(
    Core.HARDWARE_OPTIONS.find(
      (option) => option.macType === "Mac Studio" && option.chip === "M5 Ultra",
    ).ramOptions,
    [96, 256, 512],
  );
  assert.equal(
    Core.HARDWARE_OPTIONS.find(
      (option) => option.macType === "Mac Mini" && option.chip === "M6",
    ).bandwidthGBs,
    170,
  );
});
