(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DarkbloomEarnings = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const DEFAULT_DUTY_CYCLE_PERCENT = 25;
  const DECODE_BANDWIDTH_EFFICIENCY = 0.65;
  const GEMMA_DECODE_BANDWIDTH_EFFICIENCY = 0.47;
  const PREFILL_TO_DECODE_RATIO = 12;
  const ENGINE_MAX_CONCURRENT = 4;
  const TYPICAL_PROMPT_TOKENS = 3200;
  const TYPICAL_COMPLETION_TOKENS = 400;
  const MONTH_SECONDS = 30 * 24 * 60 * 60;
  const MIN_PROVIDER_MEMORY_GB = 48;
  const QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION = 700000;
  const SERVABILITY_CAP_FRACTION = 0.9;
  const ACTIVATION_RESERVE_GB = 5.5;
  const KV_BYTES_PER_TOKEN = 400000;
  const BYTES_PER_GIB = 1 << 30;
  const COLD_WEIGHT_PAD = 1.2 * (1e9 / BYTES_PER_GIB);
  const PREFILL_BATCH_UNIT_GAIN = 0.25;
  const BATCH_SCALE_AT_4 = {
    gemma_moe: 1.92,
    moe: 3.8,
    dense: 3.2,
  };
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

  function catalogModel(spec) {
    return Object.assign({}, spec, {
      bytesPerParameter: spec.sizeGB / (spec.totalParameterCount / 1000000000),
    });
  }

  const CALCULATOR_MODELS = [
    catalogModel({
      id: "Qwen3.5-9B",
      displayName: "Qwen 3.5 9B",
      minRAMGB: 24,
      sizeGB: 6.114,
      totalParameterCount: 9000000000,
      activeParameterCount: 9000000000,
      inputPriceMicroUSDPerMillion: 80000,
      outputPriceMicroUSDPerMillion: 130000,
      family: "dense",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "gpt-oss-20b",
      displayName: "GPT-OSS 20B",
      minRAMGB: 24,
      sizeGB: 12.104,
      totalParameterCount: 20000000000,
      activeParameterCount: 3600000000,
      inputPriceMicroUSDPerMillion: 20000,
      outputPriceMicroUSDPerMillion: 100000,
      family: "moe",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "gemma-4-26b-qat-4bit",
      displayName: "Gemma 4 26B",
      minRAMGB: 36,
      sizeGB: 15.641,
      totalParameterCount: 26000000000,
      activeParameterCount: 4000000000,
      inputPriceMicroUSDPerMillion: 42000,
      outputPriceMicroUSDPerMillion: 220000,
      family: "gemma_moe",
      decodeBandwidthEfficiency: GEMMA_DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "EigenLabs/Qwen3.8-27B-4bit-mtp",
      displayName: "Qwen 3.8 27B",
      minRAMGB: 36,
      sizeGB: 16.32,
      totalParameterCount: 27000000000,
      activeParameterCount: 27000000000,
      inputPriceMicroUSDPerMillion: 150000,
      outputPriceMicroUSDPerMillion: 2000000,
      family: "dense",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "qwen3-vl-30b-a3b-instruct",
      displayName: "Qwen3-VL 30B A3B Instruct",
      minRAMGB: 32,
      sizeGB: 18.268,
      totalParameterCount: 30000000000,
      activeParameterCount: 3000000000,
      inputPriceMicroUSDPerMillion: 90000,
      outputPriceMicroUSDPerMillion: 400000,
      family: "moe",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "nvidia-nemotron-3.5-lightning",
      displayName: "Nemotron 3.5 Lightning",
      minRAMGB: 48,
      sizeGB: 18.544,
      totalParameterCount: 30000000000,
      activeParameterCount: 3000000000,
      inputPriceMicroUSDPerMillion: 65000,
      outputPriceMicroUSDPerMillion: 180000,
      family: "moe",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "qwen3.5-35b-a3b",
      displayName: "Qwen3.5 35B A3B",
      minRAMGB: 36,
      sizeGB: 20.894,
      totalParameterCount: 35000000000,
      activeParameterCount: 3000000000,
      inputPriceMicroUSDPerMillion: 80000,
      outputPriceMicroUSDPerMillion: 750000,
      family: "moe",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
    catalogModel({
      id: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
      displayName: "Qwen 3.6 35B A3B",
      minRAMGB: 32,
      sizeGB: 21.309,
      totalParameterCount: 35000000000,
      activeParameterCount: 3000000000,
      inputPriceMicroUSDPerMillion: 50000,
      outputPriceMicroUSDPerMillion: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
      family: "moe",
      decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
    }),
  ];

  function activeWeightGBPerToken(model) {
    return model.activeParameterCount * model.bytesPerParameter / 1000000000;
  }

  function singleStreamDecodeTps(model, hardware) {
    return hardware.bandwidthGBs * model.decodeBandwidthEfficiency / activeWeightGBPerToken(model);
  }

  function tokenBudgetTokens(memoryGB, sizeGB) {
    const weightsGB = sizeGB * COLD_WEIGHT_PAD;
    const postLoadGB = SERVABILITY_CAP_FRACTION * memoryGB - weightsGB;
    if (postLoadGB <= 0) return 0;
    const tokens =
      (postLoadGB * BYTES_PER_GIB - ACTIVATION_RESERVE_GB * BYTES_PER_GIB) / KV_BYTES_PER_TOKEN;
    if (tokens <= 0) return 0;
    return Math.floor(tokens);
  }

  function maxConcurrencyFor(model, memoryGB) {
    const budget = tokenBudgetTokens(memoryGB, model.sizeGB);
    const requestTokens = TYPICAL_PROMPT_TOKENS + TYPICAL_COMPLETION_TOKENS;
    if (budget <= 0) return 1;
    return Math.max(1, Math.min(ENGINE_MAX_CONCURRENT, Math.floor(budget / requestTokens)));
  }

  function effectiveConcurrencyFor(maxConcurrency, dutyCyclePercent) {
    return 1 + (maxConcurrency - 1) * (dutyCyclePercent / 100);
  }

  function decodeBatchScale(family, concurrency) {
    if (concurrency <= 1) return 1;
    const unitGain = (BATCH_SCALE_AT_4[family] - 1) / 3;
    return 1 + (concurrency - 1) * unitGain;
  }

  function prefillBatchScale(concurrency) {
    if (concurrency <= 1) return 1;
    return 1 + (concurrency - 1) * PREFILL_BATCH_UNIT_GAIN;
  }

  function calculateCapacityRevenue(model, hardware, memoryGB, dutyCyclePercent) {
    const duty = dutyCyclePercent === undefined ? DEFAULT_DUTY_CYCLE_PERCENT : dutyCyclePercent;
    if (
      memoryGB < model.minRAMGB ||
      model.activeParameterCount <= 0 ||
      model.bytesPerParameter <= 0 ||
      model.inputPriceMicroUSDPerMillion <= 0 ||
      model.outputPriceMicroUSDPerMillion <= 0 ||
      hardware.bandwidthGBs <= 0 ||
      duty < 0 || duty > 100
    ) return null;

    const weightGB = activeWeightGBPerToken(model);
    const decodeTokensPerSecond = singleStreamDecodeTps(model, hardware);
    const prefillTokensPerSecond = decodeTokensPerSecond * PREFILL_TO_DECODE_RATIO;
    const tokenBudget = tokenBudgetTokens(memoryGB, model.sizeGB);
    const maxConcurrency = maxConcurrencyFor(model, memoryGB);
    const effectiveConcurrency = effectiveConcurrencyFor(maxConcurrency, duty);
    const batchedDecodeTokensPerSecond =
      decodeTokensPerSecond * decodeBatchScale(model.family, effectiveConcurrency);
    const batchedPrefillTokensPerSecond =
      prefillTokensPerSecond * prefillBatchScale(effectiveConcurrency);
    if (batchedDecodeTokensPerSecond <= 0 || batchedPrefillTokensPerSecond <= 0) return null;

    const requestSeconds =
      TYPICAL_PROMPT_TOKENS / batchedPrefillTokensPerSecond +
      TYPICAL_COMPLETION_TOKENS / batchedDecodeTokensPerSecond;
    const activeSecondsPerMonth = MONTH_SECONDS * duty / 100;
    const monthlyRequests = 1 / requestSeconds * activeSecondsPerMonth;
    const promptTokensPerMonth = monthlyRequests * TYPICAL_PROMPT_TOKENS;
    const outputTokensPerMonth = monthlyRequests * TYPICAL_COMPLETION_TOKENS;
    const inputPriceUSDPerMillion = model.inputPriceMicroUSDPerMillion / 1000000;
    const outputPriceUSDPerMillion = model.outputPriceMicroUSDPerMillion / 1000000;
    const inputRevenueUSD = promptTokensPerMonth / 1000000 * inputPriceUSDPerMillion;
    const outputRevenueUSD = outputTokensPerMonth / 1000000 * outputPriceUSDPerMillion;
    const monthlyRevenueUSD = inputRevenueUSD + outputRevenueUSD;
    if (!Number.isFinite(monthlyRevenueUSD) || monthlyRevenueUSD < 0) return null;
    return {
      model: model,
      activeWeightGBPerToken: weightGB,
      decodeTokensPerSecond: decodeTokensPerSecond,
      prefillTokensPerSecond: prefillTokensPerSecond,
      maxConcurrency: maxConcurrency,
      effectiveConcurrency: effectiveConcurrency,
      tokenBudget: tokenBudget,
      batchedDecodeTokensPerSecond: batchedDecodeTokensPerSecond,
      batchedPrefillTokensPerSecond: batchedPrefillTokensPerSecond,
      dutyCyclePercent: duty,
      activeSecondsPerMonth: activeSecondsPerMonth,
      typicalPromptTokens: TYPICAL_PROMPT_TOKENS,
      typicalCompletionTokens: TYPICAL_COMPLETION_TOKENS,
      promptTokensPerMonth: promptTokensPerMonth,
      outputTokensPerMonth: outputTokensPerMonth,
      inputPriceUSDPerMillion: inputPriceUSDPerMillion,
      outputPriceUSDPerMillion: outputPriceUSDPerMillion,
      inputRevenueUSD: inputRevenueUSD,
      outputRevenueUSD: outputRevenueUSD,
      monthlyRevenueUSD: monthlyRevenueUSD,
      annualRevenueUSD: monthlyRevenueUSD * 12,
    };
  }

  return {
    DEFAULT_DUTY_CYCLE_PERCENT: DEFAULT_DUTY_CYCLE_PERCENT,
    DECODE_BANDWIDTH_EFFICIENCY: DECODE_BANDWIDTH_EFFICIENCY,
    GEMMA_DECODE_BANDWIDTH_EFFICIENCY: GEMMA_DECODE_BANDWIDTH_EFFICIENCY,
    PREFILL_TO_DECODE_RATIO: PREFILL_TO_DECODE_RATIO,
    ENGINE_MAX_CONCURRENT: ENGINE_MAX_CONCURRENT,
    TYPICAL_PROMPT_TOKENS: TYPICAL_PROMPT_TOKENS,
    TYPICAL_COMPLETION_TOKENS: TYPICAL_COMPLETION_TOKENS,
    CALCULATOR_MODELS: CALCULATOR_MODELS,
    HARDWARE_OPTIONS: HARDWARE_OPTIONS,
    MIN_PROVIDER_MEMORY_GB: MIN_PROVIDER_MEMORY_GB,
    PROVIDER_HARDWARE_OPTIONS: HARDWARE_OPTIONS,
    QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
    calculateCapacityRevenue: calculateCapacityRevenue,
    tokenBudgetTokens: tokenBudgetTokens,
    maxConcurrencyFor: maxConcurrencyFor,
  };
});
