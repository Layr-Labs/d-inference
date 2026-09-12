import { describe, expect, it } from "vitest";
import type { Model } from "@/lib/api";
import { buildCatalogPrices, filterModels, formatPrice, modelContext, modelFeatures } from "./catalog";

const ALPHA = "example/alpha";
const BETA = "example/beta";
const GAMMA = "example/gamma";
const models: Model[] = [
  { id: ALPHA, object: "model", display_name: "Alpha 2", family: "Qwen", context_length: 32_000, capabilities: ["tools"] },
  { id: BETA, object: "model", display_name: "Beta", max_context_length: 128_000, input_modalities: ["text", "image"], supported_features: ["reasoning"] },
  { id: GAMMA, object: "model", display_name: "Gamma", capabilities: ["tools"] },
];
const prices = buildCatalogPrices({ prices: [
  { model: ALPHA, input_price: 50_000, output_price: 200_000, input_usd: "0.05", output_usd: "0.20" },
  { model: BETA, input_price: 0, output_price: 300_000, input_usd: "0", output_usd: "0.30" },
] });

describe("model catalog controls", () => {
  it("combines normalized multi-term search with advertised capability filtering", () => {
    expect(filterModels(models, "  QWEN alpha  ", "tools", "name", prices).map((model) => model.id)).toEqual([ALPHA]);
    expect(filterModels(models, "Qwen", "images", "name", prices)).toEqual([]);
    expect(filterModels(models, "reasoning image", "all", "name", prices).map((model) => model.id)).toEqual([BETA]);
  });

  it("recognizes the coordinator's capability aliases without inferring support from names", () => {
    expect(modelFeatures({ id: "vision-reasoning-model", object: "model" })).toEqual([]);
    expect(modelFeatures({ id: "model", object: "model", capabilities: [" IMAGE_INPUT ", "FUNCTION_CALLING", "thinking"] })).toEqual(["images", "tools", "reasoning"]);
  });

  it("sorts prices independently, retaining zero as a known price and putting missing prices last", () => {
    expect(filterModels(models, "", "all", "input", prices).map((model) => model.id)).toEqual([BETA, ALPHA, GAMMA]);
    expect(filterModels(models, "", "all", "output", prices).map((model) => model.id)).toEqual([ALPHA, BETA, GAMMA]);
  });

  it("sorts known context lengths descending without mutating the fetched catalog", () => {
    expect(filterModels(models, "", "all", "context", prices).map((model) => model.id)).toEqual([BETA, ALPHA, GAMMA]);
    expect(models[0].id).toBe(ALPHA);
    expect(modelContext({ id: "bad", object: "model", context_length: -1 })).toBe(0);
  });

  it("converts micro-USD per million tokens without hiding free or tiny rates", () => {
    expect(formatPrice(50_000)).toBe("$0.05");
    expect(formatPrice(0)).toBe("$0.00");
    expect(formatPrice(1)).toBe("$0.000001");
    expect(formatPrice(undefined)).toBe("—");
  });

  it("does not render malformed or negative prices as valid rates", () => {
    const invalid = buildCatalogPrices({ prices: [{ model: "broken", input_price: -1, output_price: Number.NaN, input_usd: "", output_usd: "" }] });
    expect(invalid.has("broken")).toBe(false);
  });
});
