export interface PriceRow {
  id: string;
  name: string;
  input: number;
  output: number;
  context?: number;
}

export const FALLBACK_PRICES: PriceRow[] = [
  {
    id: "gemma-4-26b",
    name: "Gemma 4 26B",
    input: 0.03,
    output: 0.165,
    context: 131072,
  },
  {
    id: "gpt-oss-20b",
    name: "GPT-OSS 20B",
    input: 0.015,
    output: 0.07,
    context: 131072,
  },
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPrice(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

export function parsePricing(catalog: unknown, pricing: unknown): PriceRow[] {
  if (
    !isRecord(catalog) ||
    !Array.isArray(catalog.models) ||
    !isRecord(pricing) ||
    !Array.isArray(pricing.prices)
  )
    return [];
  const prices = new Map(
    pricing.prices.filter(isRecord).map((price) => [price.model, price]),
  );
  return catalog.models.flatMap((model: unknown) => {
    if (!isRecord(model) || typeof model.id !== "string") return [];
    const price = prices.get(model.id);
    const input = price?.input_price ?? pricing.fallback_input_price;
    const output = price?.output_price ?? pricing.fallback_output_price;
    if (!isPrice(input) || !isPrice(output)) return [];
    return [
      {
        id: model.id,
        name:
          typeof model.display_name === "string" && model.display_name
            ? model.display_name
            : model.id,
        input: input / 1_000_000,
        output: output / 1_000_000,
        context:
          typeof model.max_context_length === "number" &&
          model.max_context_length > 0
            ? model.max_context_length
            : undefined,
      },
    ];
  });
}
