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

function asString(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function asStringArray(value: unknown) {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

function aliasMemberBuilds(alias: JsonRecord, includeRetired = true) {
  const builds: string[] = [];
  const add = (build: string | undefined) => {
    if (build && !builds.includes(build)) builds.push(build);
  };
  add(asString(alias.desired_build));
  add(asString(alias.previous_build));
  if (includeRetired) {
    for (const retired of asStringArray(alias.retired_builds)) add(retired);
  }
  return builds;
}

function isHiddenStandaloneModel(model: JsonRecord) {
  const metadata = asRecord(model.metadata);
  if (metadata.hidden_from_picker === true || metadata.hide_standalone === true) return true;
  const displayName = asString(model.display_name ?? model.name) ?? "";
  return displayName.toLowerCase().includes("rollback");
}

function publicModelRows(catalogModels: unknown[], aliases: unknown[]) {
  const rawModels: JsonRecord[] = [];
  const rawByID = new Map<string, JsonRecord>();
  for (const item of catalogModels) {
    const model = asRecord(item);
    if (typeof model.id !== "string") continue;
    rawModels.push(model);
    rawByID.set(model.id, model);
  }

  const aliasRows: JsonRecord[] = [];
  const hiddenBuilds = new Set<string>();
  for (const item of aliases) {
    const alias = asRecord(item);
    if (typeof alias.id !== "string" || typeof alias.desired_build !== "string") continue;
    aliasRows.push(alias);
    for (const build of aliasMemberBuilds(alias)) hiddenBuilds.add(build);
  }

  const publicAliases: JsonRecord[] = [];
  for (const alias of aliasRows) {
    const primaryID = asString(alias.primary_build) ?? asString(alias.desired_build) ?? asString(alias.previous_build);
    const primary = primaryID ? rawByID.get(primaryID) : undefined;
    if (!primary) continue;
    publicAliases.push({
      ...primary,
      id: alias.id,
      display_name: alias.display_name ?? primary.display_name,
      name: alias.display_name ?? primary.name,
      quantization: undefined,
      metadata: {
        ...asRecord(primary.metadata),
        display_name: alias.display_name ?? asRecord(primary.metadata).display_name,
        quantization: undefined,
      },
    });
  }
  const visibleRaw = rawModels.filter((model) => !hiddenBuilds.has(model.id as string) && !isHiddenStandaloneModel(model));
  return [...publicAliases, ...visibleRaw];
}

function aggregateAliasCapacity(alias: JsonRecord, capacityByID: Map<string, JsonRecord>) {
  const members = aliasMemberBuilds(alias, false).map((build) => capacityByID.get(build)).filter(Boolean) as JsonRecord[];
  if (members.length === 0) return undefined;
  const sum = (key: string) => members.reduce((total, item) => total + (typeof item[key] === "number" ? item[key] as number : 0), 0);
  const ttfts = members
    .map((item) => item.estimated_ttft_ms)
    .filter((value): value is number => typeof value === "number" && value > 0);
  return {
    id: alias.id,
    ready: members.some((item) => item.ready === true),
    can_accept: members.some((item) => item.can_accept === true),
    routable_providers: sum("routable_providers"),
    warm_providers: sum("warm_providers"),
    cold_providers: sum("cold_providers"),
    active_requests: sum("active_requests"),
    queued_requests: sum("queued_requests"),
    queue_limit: Math.max(...members.map((item) => typeof item.queue_limit === "number" ? item.queue_limit : 0)),
    aggregate_tps: sum("aggregate_tps"),
    estimated_ttft_ms: ttfts.length > 0 ? Math.min(...ttfts) : undefined,
  };
}

function isGemmaRolloutBuild(id: unknown): id is string {
  return typeof id === "string" && GEMMA_ROLLOUT_IDS.has(id);
}

function sumGemmaCapacity(capacityModels: JsonRecord[]) {
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
    capacityByID.set(GEMMA_PUBLIC_ID, sumGemmaCapacity(capacities));
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
    fetch(`${coordUrl}/v1/models/catalog?type=text&include_aliases=1`),
    fetch(`${coordUrl}/v1/models/capacity`).catch(() => null),
  ]);

  if (!catalogRes.ok) {
    return NextResponse.json({ error: `Upstream ${catalogRes.status}` }, { status: catalogRes.status });
  }

  const catalog = asRecord(await catalogRes.json());
  const catalogModels = Array.isArray(catalog.models) ? catalog.models : [];
  const aliases = Array.isArray(catalog.aliases) ? catalog.aliases : [];

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
    for (const alias of aliases.map(asRecord)) {
      const aggregate = aggregateAliasCapacity(alias, capacityByID);
      if (aggregate && typeof aggregate.id === "string") {
        capacityByID.set(aggregate.id, aggregate);
      }
    }
  }

  return NextResponse.json({
    object: "list",
    aliases,
    data: (aliases.length > 0 ? publicModelRows(catalogModels, aliases) : applyGemmaRolloutQuickFix(catalogModels, capacityByID))
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
