import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

type JsonRecord = Record<string, unknown>;

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
    data: catalogModels
      .map(asRecord)
      .filter((model) => typeof model.id === "string")
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
