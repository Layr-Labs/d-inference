import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

type JsonRecord = Record<string, unknown>;

const GEMMA_PUBLIC_ID = "gemma-4-26b";
const GEMMA_QAT_ID = "gemma-4-26b-qat-4bit";
const GEMMA_ROLLBACK_ID = "gemma-4-26b-8bit";
const GEMMA_ROLLOUT_IDS = new Set([GEMMA_PUBLIC_ID, GEMMA_QAT_ID, GEMMA_ROLLBACK_ID]);

function asRecord(value: unknown): JsonRecord {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : {};
}

function toModelEntry(model: JsonRecord, capacity?: JsonRecord) {
  const metadata = asRecord(model.metadata);
  return {
    id: model.id,
    object: model.object || "model",
    created: model.created || 0,
    owned_by: model.owned_by || "eigeninference",
    // OpenRouter-shaped top-level fields (present on /v1/models and the
    // enriched catalog). Passed through so the UI can render them.
    name: model.name ?? metadata.display_name,
    hugging_face_id: model.hugging_face_id ?? model.id,
    description: model.description ?? metadata.description,
    context_length: model.context_length ?? model.max_context_length ?? metadata.max_context_length,
    max_output_length: model.max_output_length ?? metadata.max_output_length,
    quantization: model.quantization ?? metadata.quantization,
    pricing: model.pricing,
    input_modalities: model.input_modalities,
    output_modalities: model.output_modalities,
    supported_features: model.supported_features,
    supported_sampling_parameters: model.supported_sampling_parameters,
    metadata: {
      ...metadata,
      model_type: model.model_type ?? metadata.model_type,
      quantization: model.quantization ?? metadata.quantization,
      provider_count:
        model.provider_count ?? metadata.provider_count ?? capacity?.routable_providers ?? 0,
      routable_providers: capacity?.routable_providers ?? metadata.routable_providers ?? 0,
      warm_providers: capacity?.warm_providers ?? metadata.warm_providers ?? 0,
      can_accept: capacity?.can_accept ?? metadata.can_accept ?? false,
      trust_level: model.trust_level ?? metadata.trust_level,
      display_name: model.display_name ?? metadata.display_name,
      size_bytes: model.size_bytes ?? model.total_size_bytes ?? metadata.size_bytes,
      size_gb: model.size_gb ?? metadata.size_gb,
      min_ram_gb: model.min_ram_gb ?? metadata.min_ram_gb,
      max_context_length: model.max_context_length ?? metadata.max_context_length,
      max_output_length: model.max_output_length ?? metadata.max_output_length,
      architecture: model.architecture ?? metadata.architecture,
      family: model.family ?? metadata.family,
      capabilities: model.capabilities ?? metadata.capabilities,
    },
  };
}

function isGemmaRolloutBuild(id: unknown): id is string {
  return typeof id === "string" && GEMMA_ROLLOUT_IDS.has(id);
}

function sumCapacity(capacityModels: JsonRecord[]) {
  const sum = (key: string) => capacityModels.reduce((total, model) => total + (typeof model[key] === "number" ? model[key] as number : 0), 0);
  const ttfts = capacityModels
    .map((model) => model.estimated_ttft_ms)
    .filter((value): value is number => typeof value === "number" && value > 0);
  return {
    id: GEMMA_PUBLIC_ID,
    ready: capacityModels.some((model) => model.ready === true),
    can_accept: capacityModels.some((model) => model.can_accept === true),
    routable_providers: sum("routable_providers"),
    warm_providers: sum("warm_providers"),
    cold_providers: sum("cold_providers"),
    active_requests: sum("active_requests"),
    queued_requests: sum("queued_requests"),
    queue_limit: Math.max(...capacityModels.map((model) => typeof model.queue_limit === "number" ? model.queue_limit : 0)),
    aggregate_tps: sum("aggregate_tps"),
    estimated_ttft_ms: ttfts.length > 0 ? Math.min(...ttfts) : undefined,
  };
}

function applyGemmaRolloutQuickFix(catalogModels: unknown[], capacityByID: Map<string, JsonRecord>) {
  // Temporary Gemma 4 rollout shim. Remove after the coordinator alias catalog
  // contract is deployed and the console consumes alias metadata.
  const rows = catalogModels.map(asRecord).filter((model) => typeof model.id === "string");
  const publicRow = rows.find((model) => model.id === GEMMA_PUBLIC_ID);
  const qatRow = rows.find((model) => model.id === GEMMA_QAT_ID);
  const primary = publicRow ?? qatRow;
  const visible = rows.filter((model) => !isGemmaRolloutBuild(model.id));
  const capacities = [...GEMMA_ROLLOUT_IDS]
    .map((id) => capacityByID.get(id))
    .filter((capacity): capacity is JsonRecord => Boolean(capacity));

  if (capacities.length > 0) {
    capacityByID.set(GEMMA_PUBLIC_ID, sumCapacity(capacities));
  }
  if (!primary) return visible;

  return [{
    ...primary,
    id: GEMMA_PUBLIC_ID,
    name: "Gemma 4 26B",
    display_name: "Gemma 4 26B",
    quantization: undefined,
    metadata: {
      ...asRecord(primary.metadata),
      display_name: "Gemma 4 26B",
      quantization: undefined,
    },
  }, ...visible];
}

async function publicCatalogResponse(coordUrl: string) {
  const [catalogRes, capacityRes] = await Promise.all([
    fetch(`${coordUrl}/v1/models/catalog?type=text`),
    fetch(`${coordUrl}/v1/models/capacity`).catch(() => null),
  ]);

  if (!catalogRes.ok) {
    return NextResponse.json({ error: `Upstream ${catalogRes.status}` }, { status: catalogRes.status });
  }

  const catalog = asRecord(await catalogRes.json());
  const catalogModels = Array.isArray(catalog.models) ? catalog.models : [];

  const capacityByID = new Map<string, JsonRecord>();
  if (capacityRes?.ok) {
    const capacity = asRecord(await capacityRes.json());
    const capacityModels = Array.isArray(capacity.models) ? capacity.models : [];
    for (const model of capacityModels) {
      const entry = asRecord(model);
      if (typeof entry.id === "string") {
        capacityByID.set(entry.id, entry);
      }
    }
  }

  return NextResponse.json({
    object: "list",
    data: applyGemmaRolloutQuickFix(catalogModels, capacityByID)
      .map((model) => toModelEntry(model, capacityByID.get(model.id as string))),
  });
}

export async function GET(req: NextRequest) {
  const coordUrl = DEFAULT_COORD;
  const apiKey = req.headers.get("x-api-key") || "";

  if (!apiKey) {
    return publicCatalogResponse(coordUrl);
  }

  const res = await fetch(`${coordUrl}/v1/models`, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
