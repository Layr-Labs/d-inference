export const runtime = "nodejs";

const API_BASE_URL = (process.env.DARKBLOOM_API_BASE_URL ?? "https://api.darkbloom.dev/v1").replace(/\/$/, "");
const CONSOLE_STATS_URL = process.env.DARKBLOOM_CONSOLE_STATS_URL ?? "https://console.darkbloom.dev/api/stats";
const REQUEST_TIMEOUT_MS = 7_000;

type RawStats = {
  total_gpu_cores?: number;
  total_cpu_cores?: number;
  total_memory_gb?: number;
};

type RawModel = {
  id?: string;
  active?: boolean;
  status?: string;
  model_type?: string;
  display_name?: string;
  name?: string;
  architecture?: string;
  description?: string;
  max_context_length?: number;
  min_ram_gb?: number;
  size_gb?: number;
};

type RawCatalog = { models?: RawModel[] };

type RawPrice = {
  model?: string;
  input_price?: number;
  output_price?: number;
};

type RawPricing = { prices?: RawPrice[] };

function finiteNonNegative(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

async function fetchJSON<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    cache: "no-store",
    headers: { accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Darkbloom API returned ${response.status}`);
  return response.json() as Promise<T>;
}

async function fetchConsoleStats(signal: AbortSignal): Promise<RawStats> {
  const response = await fetch(CONSOLE_STATS_URL, {
    cache: "no-store",
    headers: { accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Darkbloom console returned ${response.status}`);
  return response.json() as Promise<RawStats>;
}

function baseModelKey(id: string) {
  let key = id.toLowerCase().trim();
  const suffix = /-(qat|q4|q8|int4|int8|4bit|8bit|4-bit|8-bit|bf16|fp16|mxfp4|mxfp8|nf4|gguf|rollback|preview|beta|rc\d*)$/;
  let previous = "";
  while (key !== previous) {
    previous = key;
    key = key.replace(suffix, "");
  }
  return key;
}

function variantPenalty(model: RawModel) {
  const text = `${model.display_name ?? ""} ${model.id ?? ""}`.toLowerCase();
  let penalty = 0;
  if (/\(|rollback|preview|\brc\b/.test(text)) penalty += 100;
  if (/qat|int4|int8|fp16|bf16|mxfp4|mxfp8|nf4|\d\s*-?bit/.test(text)) penalty += 10;
  return penalty + (model.id?.length ?? 0) * 0.01;
}

function normalizeModels(catalog: RawCatalog | null, pricing: RawPricing | null) {
  const prices = new Map(
    (pricing?.prices ?? [])
      .filter((price): price is Required<Pick<RawPrice, "model">> & RawPrice => Boolean(price.model))
      .map((price) => [price.model, price]),
  );
  const canonical = new Map<string, RawModel>();

  for (const model of catalog?.models ?? []) {
    if (!model.id || model.active === false || model.model_type !== "text") continue;
    const key = baseModelKey(model.id);
    const current = canonical.get(key);
    if (!current || variantPenalty(model) < variantPenalty(current)) canonical.set(key, model);
  }

  return [...canonical.values()].map((model) => {
    const price = prices.get(model.id ?? "") ?? prices.get(baseModelKey(model.id ?? ""));
    return {
      id: model.id,
      name: model.display_name || model.name || model.id,
      architecture: model.architecture || "Open-source text model",
      description: model.description || "Available on the Darkbloom grid.",
      contextLength: finiteNonNegative(model.max_context_length) ? model.max_context_length : null,
      minRamGB: finiteNonNegative(model.min_ram_gb) ? model.min_ram_gb : null,
      sizeGB: finiteNonNegative(model.size_gb) ? model.size_gb : null,
      inputPriceMicro: finiteNonNegative(price?.input_price) ? price.input_price : 50_000,
      outputPriceMicro: finiteNonNegative(price?.output_price) ? price.output_price : 200_000,
      status: model.status || "active",
    };
  });
}

export async function GET() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const [stats, catalog, pricing] = await Promise.all([
      fetchConsoleStats(controller.signal).catch(() => null),
      fetchJSON<RawCatalog>("/models/catalog?type=text&include_aliases=1", controller.signal).catch(() => null),
      fetchJSON<RawPricing>("/pricing", controller.signal).catch(() => null),
    ]);
    const models = normalizeModels(catalog, pricing);

    if (!stats && models.length === 0) {
      return Response.json(
        { available: false, stats: null, models: [], generatedAt: new Date().toISOString() },
        { status: 503, headers: { "cache-control": "no-store" } },
      );
    }

    return Response.json(
      {
        available: true,
        stats: stats
          ? {
              gpuCores: finiteNonNegative(stats.total_gpu_cores) ? stats.total_gpu_cores : null,
              cpuCores: finiteNonNegative(stats.total_cpu_cores) ? stats.total_cpu_cores : null,
              memoryGB: finiteNonNegative(stats.total_memory_gb) ? stats.total_memory_gb : null,
            }
          : null,
        models,
        generatedAt: new Date().toISOString(),
        degraded: !stats || models.length === 0,
      },
      { headers: { "cache-control": "public, s-maxage=30, stale-while-revalidate=120" } },
    );
  } finally {
    clearTimeout(timeout);
  }
}
