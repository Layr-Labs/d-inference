import { describe, it, expect } from "vitest";
import type { Model, PricingResponse } from "@/lib/api";
import {
  type MacConfig,
  type CatalogModel,
  DEFAULT_OUTPUT_PRICE_MICRO_USD,
  DEFAULT_INPUT_PRICE_MICRO_USD,
  tierFloorUSD,
  availFromUptime,
  scaledFloorUSD,
  buildPricingLookup,
  buildCatalogModels,
  baseModelKey,
  modelSizeGB,
  activeParamsGB,
  calculateModelEarnings,
  calculatePortfolioEarnings,
  fmtUSD,
  fmtUSDWhole,
} from "./calc";

// Pure earnings-math coverage. The /earn E2E pins only the base-reward floor
// table ($16 -> $18 on a RAM-tier change); this guards the historically-buggy
// throughput -> revenue -> net core (the file header notes a past ~10-20x
// overstatement), so a regression in the batch/utilization factors is caught.

const CONFIG: MacConfig = {
  macType: "Test",
  chip: "T",
  ramOptions: [64],
  bandwidthGBs: 400,
  idleWatts: 20,
  inferWatts: 60, // marginal draw = 40W
};

const MODEL: CatalogModel = {
  id: "m",
  name: "M",
  minRAMGB: 13,
  demandNote: "",
  activeParamsGB: 8,
  modelSizeGB: 9,
  outputPriceMicro: 300_000, // $0.30 / 1M output tokens
  inputPriceMicro: 100_000, // $0.10 / 1M input tokens
};

function pricing(prices: Array<{ model: string; input_price: number; output_price: number }>): PricingResponse {
  return { prices } as unknown as PricingResponse;
}

function model(over: Partial<Model> & { id: string }): Model {
  return { object: "model", ...over };
}

describe("base-reward floor", () => {
  it("maps unified memory to the right tier", () => {
    expect(tierFloorUSD(48)).toBe(16);
    expect(tierFloorUSD(64)).toBe(18);
    expect(tierFloorUSD(512)).toBe(40);
    expect(tierFloorUSD(20)).toBe(0); // under the 24GB tier earns no floor
  });

  it("ramps the floor by uptime (0 at <=90%, full at 100%)", () => {
    expect(availFromUptime(1)).toBe(1);
    expect(availFromUptime(0.9)).toBe(0);
    expect(availFromUptime(0.95)).toBeCloseTo(0.5, 5);
    expect(availFromUptime(0.5)).toBe(0); // clamped
    expect(availFromUptime(2)).toBe(1); // clamped
    expect(scaledFloorUSD(48, 1)).toBe(16);
    expect(scaledFloorUSD(64, 0.95)).toBeCloseTo(9, 5); // 18 * 0.5
  });
});

describe("calculateModelEarnings (usage throughput -> revenue)", () => {
  it("applies single-stream x 4x batch x 80% utilization and nets electricity", () => {
    const e = calculateModelEarnings(MODEL, CONFIG, 24, 0.15);
    // single = (400/8)*0.6 = 30; decode = 30 * 4 * 0.8 = 96 tok/s
    expect(e.decodeTokPerSec).toBeCloseTo(96, 5);
    // rev/hr = (96*3600/1e6 * 0.30) + (that * 3.5 * 0.10) = 0.10368 + 0.12096
    expect(e.revenuePerHour).toBeCloseTo(0.22464, 5);
    // elec/hr = (40/1000) * 0.15 * 0.8
    expect(e.elecPerHour).toBeCloseTo(0.0048, 6);
    // monthly net is USAGE ONLY here (the floor is added at the portfolio level)
    expect(e.monthlyNet).toBeCloseTo(158.2848, 3); // (0.22464 - 0.0048) * 720
  });

  it("electricity cost reduces net earnings monotonically", () => {
    const cheap = calculateModelEarnings(MODEL, CONFIG, 24, 0.1);
    const pricey = calculateModelEarnings(MODEL, CONFIG, 24, 0.5);
    expect(pricey.monthlyElec).toBeGreaterThan(cheap.monthlyElec);
    expect(pricey.monthlyNet).toBeLessThan(cheap.monthlyNet);
  });
});

describe("calculatePortfolioEarnings (usage + floor - electricity)", () => {
  it("adds the base-reward floor on top of usage net", () => {
    const p = calculatePortfolioEarnings([MODEL], CONFIG, 64, 24, 0.15);
    expect(p).not.toBeNull();
    if (!p) return;
    expect(p.monthlyFloor).toBe(18); // 64GB tier @ 100% uptime
    expect(p.monthlyUsageNet).toBeCloseTo(158.2848, 3);
    expect(p.monthlyNet).toBeCloseTo(176.2848, 3); // usage + floor
    expect(p.annualNet).toBeCloseTo(176.2848 * 12, 2);
  });

  it("returns null when no models are selected", () => {
    expect(calculatePortfolioEarnings([], CONFIG, 64, 24, 0.15)).toBeNull();
  });

  it("returns null when the selected models exceed memory", () => {
    expect(calculatePortfolioEarnings([MODEL], CONFIG, 4, 24, 0.15)).toBeNull();
  });
});

describe("buildPricingLookup (defensive)", () => {
  it("maps prices by model id", () => {
    expect(buildPricingLookup(pricing([{ model: "a", input_price: 1, output_price: 2 }]))).toEqual({
      a: { input: 1, output: 2 },
    });
  });

  it("tolerates null, a missing prices field, and a non-array prices field", () => {
    expect(buildPricingLookup(null)).toEqual({});
    expect(buildPricingLookup({} as unknown as PricingResponse)).toEqual({});
    expect(buildPricingLookup({ prices: {} } as unknown as PricingResponse)).toEqual({});
  });
});

describe("buildCatalogModels", () => {
  it("derives size/active-params from the id and applies default pricing", () => {
    const [m] = buildCatalogModels([model({ id: "qwen-9b" })], null);
    expect(m).toMatchObject({
      id: "qwen-9b",
      name: "qwen-9b",
      modelSizeGB: 9,
      minRAMGB: 13, // ceil(9 * 1.35)
      activeParamsGB: 9,
      outputPriceMicro: DEFAULT_OUTPUT_PRICE_MICRO_USD,
      inputPriceMicro: DEFAULT_INPUT_PRICE_MICRO_USD,
    });
  });

  it("prefers coordinator pricing when present", () => {
    const [m] = buildCatalogModels(
      [model({ id: "qwen-9b" })],
      pricing([{ model: "qwen-9b", input_price: 111, output_price: 222 }]),
    );
    expect(m.inputPriceMicro).toBe(111);
    expect(m.outputPriceMicro).toBe(222);
  });

  it("collapses quantization variants to a single canonical entry", () => {
    const models = buildCatalogModels(
      [
        model({ id: "gemma-4-26b" }),
        model({ id: "gemma-4-26b-qat-4bit" }),
        model({ id: "gemma-4-26b-8bit" }),
      ],
      null,
    );
    expect(models).toHaveLength(1);
    expect(models[0].id).toBe("gemma-4-26b");
  });
});

describe("catalog helpers", () => {
  it("strips quant/build suffixes to a base model key", () => {
    expect(baseModelKey("gemma-4-26b-qat-4bit")).toBe("gemma-4-26b");
    expect(baseModelKey("some-model-8bit")).toBe("some-model");
  });

  it("derives model size from explicit fields, then the id, then a fallback", () => {
    expect(modelSizeGB(model({ id: "x", size_gb: 12 }))).toBe(12);
    expect(modelSizeGB(model({ id: "x", size_bytes: 8e9 }))).toBeCloseTo(8, 5);
    expect(modelSizeGB(model({ id: "qwen-9b" }))).toBe(9);
    expect(modelSizeGB(model({ id: "no-digits-here" }))).toBe(27); // fallback
  });

  it("estimates active params, honoring MoE 'A_B' active counts", () => {
    expect(activeParamsGB(model({ id: "qwen-30b-a3b" }), 30)).toBe(3);
    expect(activeParamsGB(model({ id: "dense-9b" }), 9)).toBe(9);
  });
});

describe("currency formatting", () => {
  it("formats USD with sign and precision", () => {
    expect(fmtUSD(16)).toBe("$16.00");
    expect(fmtUSD(-1.5)).toBe("-$1.50");
    expect(fmtUSD(0.1234, 4)).toBe("$0.1234");
    expect(fmtUSDWhole(176.28)).toBe("$176");
  });
});
