(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DarkbloomEarnings = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const DEFAULT_DUTY_CYCLE_PERCENT = 5;
  const DECODE_BANDWIDTH_EFFICIENCY = 0.65;
  const MONTH_SECONDS = 30 * 24 * 60 * 60;
  const MIN_PROVIDER_MEMORY_GB = 48;
  const QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION = 700000;
  const MAC_CONFIGS = [
    { macType: "MacBook Pro", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68 },
    { macType: "MacBook Pro", chip: "M1 Pro", ramOptions: [16, 32], bandwidthGBs: 200 },
    { macType: "MacBook Pro", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400 },
    { macType: "MacBook Pro", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100 },
    { macType: "MacBook Pro", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200 },
    { macType: "MacBook Pro", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400 },
    { macType: "MacBook Pro", chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100 },
    { macType: "MacBook Pro", chip: "M3 Pro", ramOptions: [18, 36], bandwidthGBs: 150 },
    { macType: "MacBook Pro", chip: "M3 Max (14-core CPU)", ramOptions: [36, 96], bandwidthGBs: 300 },
    { macType: "MacBook Pro", chip: "M3 Max (16-core CPU)", ramOptions: [48, 64, 128], bandwidthGBs: 400 },
    { macType: "MacBook Pro", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120 },
    { macType: "MacBook Pro", chip: "M4 Pro", ramOptions: [24, 48], bandwidthGBs: 273 },
    { macType: "MacBook Pro", chip: "M4 Max (14-core CPU)", ramOptions: [36], bandwidthGBs: 410 },
    { macType: "MacBook Pro", chip: "M4 Max (16-core CPU)", ramOptions: [48, 64, 128], bandwidthGBs: 546 },
    { macType: "MacBook Pro", chip: "M5", ramOptions: [16, 24, 32], bandwidthGBs: 153 },
    { macType: "MacBook Pro", chip: "M5 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 307 },
    { macType: "MacBook Pro", chip: "M5 Max (32-core GPU)", ramOptions: [36], bandwidthGBs: 460 },
    { macType: "MacBook Pro", chip: "M5 Max (40-core GPU)", ramOptions: [48, 64, 128], bandwidthGBs: 614 },
    { macType: "Mac Mini", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68 },
    { macType: "Mac Mini", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100 },
    { macType: "Mac Mini", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200 },
    { macType: "Mac Mini", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120 },
    { macType: "Mac Mini", chip: "M4 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 273 },
    { macType: "Mac Mini", chip: "M5 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 307 },
    { macType: "Mac Mini", chip: "M6", ramOptions: [16, 24, 32], bandwidthGBs: 170 },
    { macType: "Mac Studio", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400 },
    { macType: "Mac Studio", chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800 },
    { macType: "Mac Studio", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400 },
    { macType: "Mac Studio", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800 },
    { macType: "Mac Studio", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819 },
    { macType: "Mac Studio", chip: "M5 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 1200 },
    { macType: "Mac Studio", chip: "M4 Max (14-core CPU)", ramOptions: [36], bandwidthGBs: 410 },
    { macType: "Mac Studio", chip: "M4 Max (16-core CPU)", ramOptions: [48, 64, 128], bandwidthGBs: 546 },
    { macType: "Mac Studio", chip: "M5 Max (32-core GPU)", ramOptions: [36], bandwidthGBs: 460 },
    { macType: "Mac Studio", chip: "M5 Max (40-core GPU)", ramOptions: [48, 64, 128], bandwidthGBs: 614 },
    { macType: "Mac Pro", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800 },
  ];
  const CHIP_ORDER = [
    "M1", "M1 Pro", "M1 Max", "M1 Ultra",
    "M2", "M2 Pro", "M2 Max", "M2 Ultra",
    "M3", "M3 Pro", "M3 Max (14-core CPU)", "M3 Max (16-core CPU)", "M3 Ultra",
    "M4", "M4 Pro", "M4 Max (14-core CPU)", "M4 Max (16-core CPU)",
    "M5", "M5 Pro", "M5 Max (32-core GPU)", "M5 Max (40-core GPU)", "M5 Ultra", "M6",
  ];
  const MAC_TYPE_ORDER = ["MacBook Pro", "Mac Mini", "Mac Studio", "Mac Pro"];
  const HARDWARE_OPTIONS = MAC_CONFIGS.map(function (config) {
    return Object.assign({}, config, {
      id: config.macType + ":" + config.chip,
      ramOptions: config.ramOptions.slice().sort(function (a, b) { return a - b; }),
    });
  }).sort(function (a, b) {
    const chipDelta = CHIP_ORDER.indexOf(a.chip) - CHIP_ORDER.indexOf(b.chip);
    return chipDelta || MAC_TYPE_ORDER.indexOf(a.macType) - MAC_TYPE_ORDER.indexOf(b.macType);
  });

  const CALCULATOR_MODELS = [
    {
      id: "qwen3.6-35b-a3b-mxfp8",
      displayName: "Qwen3.6 35B A3B",
      minRAMGB: 48,
      sizeGB: 22,
      activeParameterCount: 3000000000,
      bytesPerParameter: 22 / 35,
      outputPriceMicroUSDPerMillion: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
    },
    {
      id: "gemma-4-26b-a4b-mxfp8",
      displayName: "Gemma 4 26B A4B",
      minRAMGB: 32,
      sizeGB: 17,
      activeParameterCount: 4000000000,
      bytesPerParameter: 17 / 26,
      outputPriceMicroUSDPerMillion: 220000,
    },
    {
      id: "gpt-oss-20b-mxfp4",
      displayName: "GPT-OSS 20B",
      minRAMGB: 24,
      sizeGB: 12,
      activeParameterCount: 3600000000,
      bytesPerParameter: 12 / 20,
      outputPriceMicroUSDPerMillion: 69000,
    },
  ];

  function calculateCapacityRevenue(model, hardware, memoryGB, dutyCyclePercent) {
    const duty = dutyCyclePercent === undefined ? DEFAULT_DUTY_CYCLE_PERCENT : dutyCyclePercent;
    if (
      memoryGB < model.minRAMGB ||
      model.activeParameterCount <= 0 ||
      model.bytesPerParameter <= 0 ||
      model.outputPriceMicroUSDPerMillion <= 0 ||
      hardware.bandwidthGBs <= 0 ||
      duty < 0 || duty > 100
    ) return null;

    const activeWeightGBPerToken =
      model.activeParameterCount * model.bytesPerParameter / 1000000000;
    const decodeTokensPerSecond =
      hardware.bandwidthGBs * DECODE_BANDWIDTH_EFFICIENCY / activeWeightGBPerToken;
    const activeSecondsPerMonth = MONTH_SECONDS * duty / 100;
    const outputTokensPerMonth = decodeTokensPerSecond * activeSecondsPerMonth;
    const outputPriceUSDPerMillion = model.outputPriceMicroUSDPerMillion / 1000000;
    const monthlyRevenueUSD = outputTokensPerMonth / 1000000 * outputPriceUSDPerMillion;
    if (!Number.isFinite(monthlyRevenueUSD)) return null;
    return {
      model: model,
      activeWeightGBPerToken: activeWeightGBPerToken,
      decodeTokensPerSecond: decodeTokensPerSecond,
      dutyCyclePercent: duty,
      activeSecondsPerMonth: activeSecondsPerMonth,
      outputTokensPerMonth: outputTokensPerMonth,
      outputPriceUSDPerMillion: outputPriceUSDPerMillion,
      monthlyRevenueUSD: monthlyRevenueUSD,
      annualRevenueUSD: monthlyRevenueUSD * 12,
    };
  }

  return {
    DEFAULT_DUTY_CYCLE_PERCENT: DEFAULT_DUTY_CYCLE_PERCENT,
    DECODE_BANDWIDTH_EFFICIENCY: DECODE_BANDWIDTH_EFFICIENCY,
    CALCULATOR_MODELS: CALCULATOR_MODELS,
    HARDWARE_OPTIONS: HARDWARE_OPTIONS,
    MIN_PROVIDER_MEMORY_GB: MIN_PROVIDER_MEMORY_GB,
    PROVIDER_HARDWARE_OPTIONS: HARDWARE_OPTIONS,
    QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
    calculateCapacityRevenue: calculateCapacityRevenue,
  };
});
