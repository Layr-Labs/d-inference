const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("./earn-calculator-core.js");

test("catalog pins current serving models, active weights, and prices", () => {
  assert.deepEqual(Core.CALCULATOR_MODELS.map((model) => model.id), [
    "Qwen3.5-9B",
    "gpt-oss-20b",
    "gemma-4-26b-qat-4bit",
    "EigenLabs/Qwen3.8-27B-4bit-mtp",
    "qwen3-vl-30b-a3b-instruct",
    "nvidia-nemotron-3.5-lightning",
    "qwen3.5-35b-a3b",
    "qwen3.6-35b-a3b-vl-mtp-mxfp8",
  ]);
  assert.deepEqual(Core.CALCULATOR_MODELS.map((model) => model.activeParameterCount), [
    9_000_000_000,
    3_600_000_000,
    4_000_000_000,
    27_000_000_000,
    3_000_000_000,
    3_000_000_000,
    3_000_000_000,
    3_000_000_000,
  ]);
  assert.deepEqual(Core.CALCULATOR_MODELS.map((model) => model.outputPriceMicroUSDPerMillion), [
    130_000,
    100_000,
    220_000,
    2_000_000,
    400_000,
    180_000,
    750_000,
    700_000,
  ]);
});

test("default duty cycle is 25%", () => {
  assert.equal(Core.DEFAULT_DUTY_CYCLE_PERCENT, 25);
});

test("projection uses measured mix, prefill, and KV-limited concurrency", () => {
  const model = Core.CALCULATOR_MODELS.find((entry) => entry.id === "qwen3.6-35b-a3b-vl-mtp-mxfp8");
  const hardware = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  const estimate = Core.calculateCapacityRevenue(model, hardware, 48, 25);
  assert.ok(estimate);
  assert.equal(estimate.activeSecondsPerMonth, 180 * 60 * 60);
  assert.equal(estimate.typicalPromptTokens, 3200);
  assert.equal(estimate.typicalCompletionTokens, 400);
  assert.ok(estimate.prefillTokensPerSecond > estimate.decodeTokensPerSecond);
  assert.ok(estimate.inputRevenueUSD > 0);
  assert.ok(estimate.outputRevenueUSD > 0);
  assert.ok(Math.abs(estimate.monthlyRevenueUSD - (estimate.inputRevenueUSD + estimate.outputRevenueUSD)) < 1e-12);
  assert.equal(estimate.maxConcurrency, 4);
  assert.ok(estimate.effectiveConcurrency > 1);
  assert.ok(estimate.effectiveConcurrency < estimate.maxConcurrency);
});

test("higher duty increases overlap, so revenue is superlinear", () => {
  const model = Core.CALCULATOR_MODELS.find((entry) => entry.id === "qwen3.6-35b-a3b-vl-mtp-mxfp8");
  const hardware = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  const low = Core.calculateCapacityRevenue(model, hardware, 48, 25);
  const high = Core.calculateCapacityRevenue(model, hardware, 48, 50);
  assert.ok(high.monthlyRevenueUSD > low.monthlyRevenueUSD * 2);
});

test("a model that does not fit returns null", () => {
  const nemotron = Core.CALCULATOR_MODELS.find((entry) => entry.id === "nvidia-nemotron-3.5-lightning");
  const hardware = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  assert.equal(Core.calculateCapacityRevenue(nemotron, hardware, 36, 25), null);
});

test("Qwen 3.8 requires an M5 or newer chip", () => {
  const qwen38 = Core.CALCULATOR_MODELS.find((entry) => entry.id === "EigenLabs/Qwen3.8-27B-4bit-mtp");
  const m4 = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  const m5 = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M5 Max (40-core GPU)",
  );
  assert.equal(Core.modelFit(qwen38, m4, 48).reason, "chip");
  assert.equal(Core.calculateCapacityRevenue(qwen38, m4, 48, 25), null);
  assert.equal(Core.modelFit(qwen38, m5, 48).fits, true);
  assert.ok(Core.calculateCapacityRevenue(qwen38, m5, 48, 25));
});

test("zero KV budget does not produce an earning estimate", () => {
  const qwen36 = Core.CALCULATOR_MODELS.find((entry) => entry.id === "qwen3.6-35b-a3b-vl-mtp-mxfp8");
  const hardware = Core.HARDWARE_OPTIONS.find(
    (option) => option.macType === "MacBook Pro" && option.chip === "M4 Max (16-core CPU)",
  );
  assert.equal(Core.tokenBudgetTokens(32, qwen36.sizeGB), 0);
  assert.equal(Core.modelFit(qwen36, hardware, 32).reason, "kv");
  assert.equal(Core.calculateCapacityRevenue(qwen36, hardware, 32, 25), null);
});

test("token budget matches the coordinator cold estimate for a 64 GB / 12 GB box", () => {
  assert.equal(Core.tokenBudgetTokens(64, 12), 103854);
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
