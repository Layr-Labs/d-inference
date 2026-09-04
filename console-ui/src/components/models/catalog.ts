import type { Model, PricingResponse } from "@/lib/api";

export type ModelFilter = "all" | "images" | "tools" | "reasoning";
export type ModelSort = "name" | "context" | "input" | "output";
export interface CatalogPrice { input: number; output: number }
export type CatalogPrices = Map<string, CatalogPrice>;

export const MODEL_FILTERS: { value: ModelFilter; label: string }[] = [
  { value: "all", label: "All models" },
  { value: "images", label: "Image input" },
  { value: "tools", label: "Tool calling" },
  { value: "reasoning", label: "Reasoning" },
];

export function modelName(model: Model): string {
  return model.display_name || model.name || model.id.split("/").pop() || model.id;
}

export function modelContext(model: Model): number {
  const context = model.context_length ?? model.max_context_length;
  return typeof context === "number" && Number.isFinite(context) && context > 0 ? context : 0;
}

// Only advertised metadata determines these filters. A model's name is not
// evidence that a deployed provider supports images, tools, or reasoning.
export function modelFeatures(model: Model): ModelFilter[] {
  const features = new Set([
    ...(model.capabilities ?? []),
    ...(model.supported_features ?? []),
  ].map((feature) => feature.trim().toLowerCase()));
  const modalities = model.input_modalities?.map((value) => value.trim().toLowerCase()) ?? [];
  const result: ModelFilter[] = [];
  if (modalities.includes("image") || ["vision", "image", "image_input", "multimodal"].some((value) => features.has(value))) {
    result.push("images");
  }
  if (["tools", "tool_use", "tool_calling", "function_calling", "functions"].some((value) => features.has(value))) {
    result.push("tools");
  }
  if (["reasoning", "thinking", "reasoning_parser"].some((value) => features.has(value))) {
    result.push("reasoning");
  }
  return result;
}

export function buildCatalogPrices(pricing: PricingResponse | null): CatalogPrices {
  const prices: CatalogPrices = new Map();
  for (const entry of pricing?.prices ?? []) {
    if (Number.isFinite(entry.input_price) && entry.input_price >= 0 && Number.isFinite(entry.output_price) && entry.output_price >= 0) {
      prices.set(entry.model, { input: entry.input_price, output: entry.output_price });
    }
  }
  return prices;
}

export function filterModels(models: Model[], query: string, filter: ModelFilter, sort: ModelSort, prices: CatalogPrices): Model[] {
  const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
  return models.filter((model) => {
    const features = modelFeatures(model);
    if (filter !== "all" && !features.includes(filter)) return false;
    const featureLabels = MODEL_FILTERS.filter((item) => features.includes(item.value)).map((item) => item.label);
    const searchable = [
      model.id, modelName(model), model.family, model.architecture, model.description,
      ...(model.capabilities ?? []), ...(model.supported_features ?? []), ...(model.input_modalities ?? []), ...featureLabels,
    ].filter(Boolean).join(" ").toLowerCase();
    return terms.every((term) => searchable.includes(term));
  }).sort((left, right) => {
    let difference = 0;
    if (sort === "context") difference = modelContext(right) - modelContext(left);
    if (sort === "input" || sort === "output") {
      const leftPrice = prices.get(left.id);
      const rightPrice = prices.get(right.id);
      // Unknown rates sort after known rates, including a legitimate zero.
      if (!leftPrice && rightPrice) return 1;
      if (leftPrice && !rightPrice) return -1;
      if (leftPrice && rightPrice) {
        difference = sort === "input" ? leftPrice.input - rightPrice.input : leftPrice.output - rightPrice.output;
      }
    }
    return difference || modelName(left).localeCompare(modelName(right), undefined, { numeric: true });
  });
}

export function formatPrice(microUsd?: number): string {
  if (microUsd === undefined) return "—";
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 6 }).format(microUsd / 1_000_000);
}

export function formatContext(tokens: number): string {
  if (!tokens) return "—";
  return new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(tokens);
}
