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
  const QUANTIZATION_SUFFIXES = new Set([
    "qat", "q4", "q8", "int4", "int8", "4bit", "8bit", "mxfp4", "mxfp8", "fp4", "fp8",
  ]);
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
    { macType: "Mac Mini", chip: "M6", ramOptions: [16, 24, 32], bandwidthGBs: 170 },
    { macType: "Mac Studio", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400 },
    { macType: "Mac Studio", chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800 },
    { macType: "Mac Studio", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400 },
    { macType: "Mac Studio", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800 },
    { macType: "Mac Studio", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819 },
    { macType: "Mac Studio", chip: "M5 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 1200 },
    { macType: "Mac Studio", chip: "M4 Max (14-core CPU)", ramOptions: [36], bandwidthGBs: 410 },
    { macType: "Mac Studio", chip: "M4 Max (16-core CPU)", ramOptions: [48, 64, 128], bandwidthGBs: 546 },
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

  function modelSizeGB(model) {
    if (model.size_gb > 0) return model.size_gb;
    if (model.size_bytes > 0) return model.size_bytes / 1000000000;
    return 0;
  }

  function modelTokens(model) {
    return [model.id, model.display_name, model.description]
      .filter(Boolean)
      .join(" ")
      .toLowerCase()
      .split(/[^a-z0-9.]+/)
      .filter(Boolean);
  }

  function billionsToken(token) {
    if (!token.endsWith("b")) return 0;
    const value = Number(token.slice(0, -1));
    return Number.isFinite(value) && value > 0 ? value : 0;
  }

  function parameterCountBillions(tokens) {
    return tokens.map(billionsToken).find(function (value) { return value > 0; }) || 0;
  }

  function activeParameterCount(tokens, totalBillions) {
    const activeToken = tokens.find(function (token) {
      return token.startsWith("a") && token.endsWith("b");
    });
    const activeIndex = tokens.indexOf("active");
    const activeBillions = activeToken
      ? billionsToken(activeToken.slice(1))
      : activeIndex > 0
        ? billionsToken(tokens[activeIndex - 1])
        : 0;
    return (activeBillions || totalBillions) * 1000000000;
  }

  function outputPrice(model) {
    if (model.id.toLowerCase().includes("qwen3.6-35b-a3b")) {
      return QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION;
    }
    const perTokenUSD = Number(model.pricing && model.pricing.completion);
    return Number.isFinite(perTokenUSD) && perTokenUSD > 0
      ? Math.round(perTokenUSD * 1000000000000)
      : 0;
  }

  function buildCalculatorModels(models) {
    const seen = new Set();
    const result = [];
    models.forEach(function (model) {
      const sizeGB = modelSizeGB(model);
      const tokens = modelTokens(model);
      const totalBillions = parameterCountBillions(tokens);
      const activeCount = activeParameterCount(tokens, totalBillions);
      const quantization = tokens[tokens.length - 1];
      const key = QUANTIZATION_SUFFIXES.has(quantization)
        ? model.id.slice(0, -(quantization.length + 1))
        : model.id;
      if (seen.has(key) || sizeGB <= 0 || totalBillions <= 0 || activeCount <= 0) return;
      seen.add(key);
      result.push({
        id: model.id,
        displayName: model.display_name || model.name || model.id,
        minRAMGB: model.min_ram_gb || Math.ceil(sizeGB * 1.35),
        sizeGB: sizeGB,
        activeParameterCount: activeCount,
        bytesPerParameter: sizeGB / totalBillions,
        outputPriceMicroUSDPerMillion: outputPrice(model),
      });
    });
    return result;
  }

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
    HARDWARE_OPTIONS: HARDWARE_OPTIONS,
    MIN_PROVIDER_MEMORY_GB: MIN_PROVIDER_MEMORY_GB,
    PROVIDER_HARDWARE_OPTIONS: HARDWARE_OPTIONS,
    QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
    buildCalculatorModels: buildCalculatorModels,
    calculateCapacityRevenue: calculateCapacityRevenue,
  };
});
