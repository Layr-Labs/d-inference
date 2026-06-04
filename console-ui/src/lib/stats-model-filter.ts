export interface ServedModel {
  id: string;
  providers: number;
}

export interface CatalogModelSummary {
  id: string;
  status: string;
  displayName?: string;
  sizeGB?: number;
  minRAMGB?: number;
  maxContextLength?: number;
  maxOutputLength?: number;
  architecture?: string;
  family?: string;
  quantization?: string;
  capabilities?: string[];
  // OpenRouter provider schema fields.
  name?: string;
  description?: string;
  supportedFeatures?: string[];
  inputModalities?: string[];
  outputModalities?: string[];
}

export interface CapacityModelSummary {
  id: string;
  ready?: boolean;
  canAccept?: boolean;
  routableProviders?: number;
  warmProviders?: number;
  coldProviders?: number;
  activeRequests?: number;
  queuedRequests?: number;
  queueLimit?: number;
  aggregateTPS?: number;
  estimatedTTFTMS?: number;
  tokenBudgetRemaining?: number;
  tokenBudgetTotal?: number;
}

export type VisibleServedModel<T extends ServedModel> = T & {
  catalogStatus: string;
};

export interface ServedModelFilterResult<T extends ServedModel> {
  visible: VisibleServedModel<T>[];
  catalogServedCount: number;
  deprecatedCount: number;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function catalogStatus(model: Record<string, unknown>): string {
  if (typeof model.status === "string" && model.status.trim()) {
    return model.status.trim();
  }
  const metadata = asRecord(model.metadata);
  return typeof metadata.status === "string" && metadata.status.trim()
    ? metadata.status.trim()
    : "active";
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function asStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const strings = value.filter((item): item is string => typeof item === "string" && item.length > 0);
  return strings.length > 0 ? strings : undefined;
}

function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined),
  ) as T;
}

export function catalogModelsFromResponse(payload: unknown): CatalogModelSummary[] {
  const body = asRecord(payload);
  let rows: unknown[] = [];
  if (Array.isArray(body.data)) {
    rows = body.data;
  } else if (Array.isArray(body.models)) {
    rows = body.models;
  }

  return rows
    .map(asRecord)
    .filter((model) => typeof model.id === "string" && model.id.trim().length > 0)
    .map((model) => {
      const metadata = asRecord(model.metadata);
      return compactObject({
        id: model.id as string,
        status: catalogStatus(model),
        displayName: asString(model.display_name ?? metadata.display_name),
        sizeGB: asNumber(model.size_gb ?? metadata.size_gb),
        minRAMGB: asNumber(model.min_ram_gb ?? metadata.min_ram_gb),
        maxContextLength: asNumber(model.max_context_length ?? metadata.max_context_length),
        maxOutputLength: asNumber(model.max_output_length ?? metadata.max_output_length),
        architecture: asString(model.architecture ?? metadata.architecture),
        family: asString(model.family ?? metadata.family),
        quantization: asString(model.quantization ?? metadata.quantization),
        capabilities: asStringArray(model.capabilities ?? metadata.capabilities),
        name: asString(model.name ?? model.display_name ?? metadata.display_name),
        description: asString(model.description ?? metadata.description),
        supportedFeatures: asStringArray(model.supported_features),
        inputModalities: asStringArray(model.input_modalities),
        outputModalities: asStringArray(model.output_modalities),
      });
    });
}

export function capacityModelsFromResponse(payload: unknown): CapacityModelSummary[] {
  const body = asRecord(payload);
  const rows = Array.isArray(body.models) ? body.models : [];

  return rows
    .map(asRecord)
    .filter((model) => typeof model.id === "string" && model.id.trim().length > 0)
    .map((model) => compactObject({
      id: model.id as string,
      ready: asBoolean(model.ready),
      canAccept: asBoolean(model.can_accept),
      routableProviders: asNumber(model.routable_providers),
      warmProviders: asNumber(model.warm_providers),
      coldProviders: asNumber(model.cold_providers),
      activeRequests: asNumber(model.active_requests),
      queuedRequests: asNumber(model.queued_requests),
      queueLimit: asNumber(model.queue_limit),
      aggregateTPS: asNumber(model.aggregate_tps),
      estimatedTTFTMS: asNumber(model.estimated_ttft_ms),
      tokenBudgetRemaining: asNumber(model.token_budget_remaining),
      tokenBudgetTotal: asNumber(model.token_budget_total),
    }));
}

function isDefaultCatalogStatus(status: string): boolean {
  const normalized = status.toLowerCase();
  return normalized !== "deprecated" && normalized !== "retired";
}

export function filterServedCatalogModels<T extends ServedModel>(
  models: T[],
  catalogModels: CatalogModelSummary[],
  includeDeprecated: boolean,
): ServedModelFilterResult<T> {
  const catalogStatusByID = new Map(catalogModels.map((model) => [model.id, model.status]));

  const decorated = models.map((model): VisibleServedModel<T> => ({
    ...model,
    catalogStatus: catalogStatusByID.get(model.id) ?? "deprecated",
  }));

  const catalogServedCount = decorated.filter((model) =>
    catalogStatusByID.has(model.id) && isDefaultCatalogStatus(model.catalogStatus)
  ).length;
  const deprecatedCount = decorated.length - catalogServedCount;
  const visible = includeDeprecated
    ? decorated
    : decorated.filter((model) =>
      catalogStatusByID.has(model.id) && isDefaultCatalogStatus(model.catalogStatus)
    );

  return {
    visible,
    catalogServedCount,
    deprecatedCount,
  };
}
