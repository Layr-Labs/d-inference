import { filterServedCatalogModels, type CatalogAliasSummary, type CatalogDataSummary, type CatalogModelSummary, type CapacityModelSummary } from "@/lib/stats-model-filter";
import type { PlatformStats } from "../platform-types";
import { isProviderRoutable, type ProviderStats } from "../provider-fleet";

interface ModelStats { id: string; providers: number }
interface ModelInventory {
  model: ModelStats;
  routable?: number;
  hardware: number;
  gpuCores: number;
  memoryGB: number;
  sharePct: number;
}
export type ActiveModelInventory = ModelInventory & {
  id: string;
  providers: number;
  catalogStatus?: string;
  catalogModel?: CatalogModelSummary;
  capacity?: CapacityModelSummary;
};

const GEMMA_PUBLIC_ID = "gemma-4-26b";
const GEMMA_QAT_ID = "gemma-4-26b-qat-4bit";
const GEMMA_ROLLBACK_ID = "gemma-4-26b-8bit";
const GEMMA_ROLLOUT_IDS = new Set([GEMMA_PUBLIC_ID, GEMMA_QAT_ID, GEMMA_ROLLBACK_ID]);

function providerServesGemmaRollout(provider: ProviderStats): boolean {
  if (provider.current_model && GEMMA_ROLLOUT_IDS.has(provider.current_model)) return true;
  return provider.models?.some((model) => GEMMA_ROLLOUT_IDS.has(model)) ?? false;
}


function gemmaRolloutProviders(providers: ProviderStats[]): ProviderStats[] {
  return providers.filter(providerServesGemmaRollout);
}

function modelProviders(modelID: string, providers: ProviderStats[], providersByModel: Map<string, ProviderStats[]>): ProviderStats[] {
  if (modelID === GEMMA_PUBLIC_ID) return gemmaRolloutProviders(providers);
  return providersByModel.get(modelID) ?? [];
}

function aliasMemberBuilds(alias: CatalogAliasSummary, includeRetired = true): string[] {
  const builds = new Set<string>();
  builds.add(alias.desiredBuild);
  if (alias.previousBuild) builds.add(alias.previousBuild);
  if (includeRetired) {
    for (const retired of alias.retiredBuilds ?? []) builds.add(retired);
  }
  return [...builds];
}

function hiddenAliasBuilds(aliases: CatalogAliasSummary[]): Set<string> {
  const hidden = new Set<string>();
  for (const alias of aliases) {
    for (const build of aliasMemberBuilds(alias)) hidden.add(build);
  }
  return hidden;
}

function buildProvidersByModel(providers: ProviderStats[]): Map<string, ProviderStats[]> {
  const byModel = new Map<string, ProviderStats[]>();
  for (const provider of providers) {
    const ids = new Set(provider.models ?? []);
    if (provider.current_model) ids.add(provider.current_model);
    for (const id of ids) {
      const bucket = byModel.get(id);
      if (bucket) {
        bucket.push(provider);
      } else {
        byModel.set(id, [provider]);
      }
    }
  }
  return byModel;
}

function modelProvidersForBuilds(buildIDs: string[], providersByModel: Map<string, ProviderStats[]>): ProviderStats[] {
  const seen = new Set<string>();
  const providers: ProviderStats[] = [];
  for (const build of buildIDs) {
    for (const provider of providersByModel.get(build) ?? []) {
      if (seen.has(provider.id)) continue;
      seen.add(provider.id);
      providers.push(provider);
    }
  }
  return providers;
}

export function publicCatalogModels(catalogModels: CatalogModelSummary[], aliases: CatalogAliasSummary[]): CatalogModelSummary[] {
  const rawByID = new Map(catalogModels.map((model) => [model.id, model]));
  const hidden = hiddenAliasBuilds(aliases);
  const aliasModels: CatalogModelSummary[] = [];
  for (const alias of aliases) {
    const primary = rawByID.get(alias.id) ??
      rawByID.get(alias.primaryBuild ?? alias.desiredBuild) ??
      (alias.previousBuild ? rawByID.get(alias.previousBuild) : undefined);
    if (!primary) continue;
    aliasModels.push({
      ...primary,
      id: alias.id,
      displayName: alias.displayName ?? primary.displayName,
      name: alias.displayName ?? primary.name,
      quantization: undefined,
    });
  }
  const visibleRaw = catalogModels.filter((model) => !hidden.has(model.id));
  return [...aliasModels, ...visibleRaw];
}

function aggregateCapacityForBuilds(alias: CatalogAliasSummary, capacityByID: Map<string, CapacityModelSummary>): CapacityModelSummary | null {
  const members = aliasMemberBuilds(alias, false)
    .map((build) => capacityByID.get(build))
    .filter((capacity): capacity is CapacityModelSummary => Boolean(capacity));
  if (members.length === 0) return null;
  const sum = (pick: (capacity: CapacityModelSummary) => number | undefined) =>
    members.reduce((total, capacity) => total + (pick(capacity) ?? 0), 0);
  const ttfts = members
    .map((capacity) => capacity.estimatedTTFTMS)
    .filter((value): value is number => value !== undefined && value > 0);
  return {
    id: alias.id,
    ready: members.some((capacity) => capacity.ready),
    canAccept: members.some((capacity) => capacity.canAccept),
    routableProviders: sum((capacity) => capacity.routableProviders),
    warmProviders: sum((capacity) => capacity.warmProviders),
    runningProviders: sum((capacity) => capacity.runningProviders),
    coldProviders: sum((capacity) => capacity.coldProviders),
    activeRequests: sum((capacity) => capacity.activeRequests),
    queuedRequests: sum((capacity) => capacity.queuedRequests),
    queueLimit: Math.max(...members.map((capacity) => capacity.queueLimit ?? 0)),
    aggregateTPS: sum((capacity) => capacity.aggregateTPS),
    estimatedTTFTMS: ttfts.length > 0 ? Math.min(...ttfts) : undefined,
    tokenBudgetRemaining: sum((capacity) => capacity.tokenBudgetRemaining),
    tokenBudgetTotal: sum((capacity) => capacity.tokenBudgetTotal),
  };
}

function publicCapacityModels(capacityModels: CapacityModelSummary[] | null, aliases: CatalogAliasSummary[]): CapacityModelSummary[] | null {
  if (!capacityModels) return null;
  const hidden = hiddenAliasBuilds(aliases);
  const byID = new Map(capacityModels.map((capacity) => [capacity.id, capacity]));
  const visible = capacityModels.filter((capacity) => !hidden.has(capacity.id));
  for (const alias of aliases) {
    const aggregate = aggregateCapacityForBuilds(alias, byID);
    if (aggregate) visible.push(aggregate);
  }
  return visible;
}

function publicModelStats(stats: PlatformStats): ModelStats[] {
  // Temporary Gemma 4 rollout fallback for deployments without alias metadata.
  const raw = stats.models.filter((model) => !GEMMA_ROLLOUT_IDS.has(model.id));
  const hasGemma = stats.models.some((model) => GEMMA_ROLLOUT_IDS.has(model.id));
  if (!hasGemma) return raw;
  return [{ id: GEMMA_PUBLIC_ID, providers: gemmaRolloutProviders(stats.providers).length }, ...raw];
}

export function buildModelInventory(stats: PlatformStats, aliases: CatalogAliasSummary[] = []): ModelInventory[] {
  const providersByModel = buildProvidersByModel(stats.providers);
  const aliasByID = new Map(aliases.map((alias) => [alias.id, alias]));
  const hidden = hiddenAliasBuilds(aliases);
  const rawModels = stats.models.filter((model) => !hidden.has(model.id));
  const aliasModels: ModelStats[] = [];
  for (const alias of aliases) {
    const providers = modelProvidersForBuilds(aliasMemberBuilds(alias, false), providersByModel);
    if (providers.length > 0) aliasModels.push({ id: alias.id, providers: providers.length });
  }
  const models = aliases.length > 0 ? [...rawModels, ...aliasModels] : publicModelStats(stats);
  const totalSlots = models.reduce((sum, model) => sum + model.providers, 0);

  return models
    .map((model) => {
      const alias = aliasByID.get(model.id);
      const providers = alias
        ? modelProvidersForBuilds(aliasMemberBuilds(alias, false), providersByModel)
        : modelProviders(model.id, stats.providers, providersByModel);
      return {
        model,
        routable: providers.length === model.providers && providers.every((provider) => typeof provider.routable === "boolean")
          ? providers.filter((provider) => isProviderRoutable(provider)).length
          : undefined,
        hardware: providers.filter((provider) => provider.trust_level === "hardware").length,
        gpuCores: providers.reduce((sum, provider) => sum + provider.gpu_cores, 0),
        memoryGB: providers.reduce((sum, provider) => sum + provider.memory_gb, 0),
        sharePct: totalSlots > 0 ? (model.providers / totalSlots) * 100 : 0,
      };
    })
    .sort((a, b) => b.model.providers - a.model.providers || a.model.id.localeCompare(b.model.id));
}

export function deprecatedModelLabel(status?: string): string | null {
  if (!status) return null;
  const normalized = status.toLowerCase();
  if (normalized === "deprecated") return "Deprecated";
  if (normalized === "retired") return "Retired";
  return null;
}

export function plainModelDescription(catalog?: CatalogModelSummary): string {
  if (!catalog) return "General-purpose text generation model.";
  const features = new Set(
    [...(catalog.capabilities ?? []), ...(catalog.supportedFeatures ?? [])]
      .map((feature) => feature.toLowerCase()),
  );
  const uses: string[] = [];
  if (features.has("reasoning")) uses.push("reasoning");
  if (features.has("tools") || features.has("tool_use") || features.has("function_calling")) {
    uses.push("tool use");
  }
  if (features.has("structured_outputs")) uses.push("structured outputs");
  if (features.has("vision") || features.has("images")) uses.push("image understanding");
  if (uses.length === 0) return "General-purpose text generation model.";
  if (uses.length === 1) return `Text model for ${uses[0]}.`;
  return `Text model for ${uses.slice(0, -1).join(", ")}, and ${uses[uses.length - 1]}.`;
}

export function modelDisplayName(item: ActiveModelInventory): string {
  return item.catalogModel?.displayName || item.model.id.split("/").pop()?.replace(/-/g, " ") || item.model.id;
}

export function prepareModelInventory(
  stats: PlatformStats,
  catalogData: CatalogDataSummary | null,
  capacityModels: CapacityModelSummary[] | null,
  includeDeprecated: boolean,
) {
  const aliases = catalogData?.aliases ?? [];
  const catalogModels = catalogData ? publicCatalogModels(catalogData.models, aliases) : null;
  const publicCapacity = publicCapacityModels(capacityModels, aliases);
  const capacityKnown = publicCapacity !== null;
  const catalogByID = new Map((catalogModels ?? []).map((model) => [model.id, model]));
  const capacityByID = new Map((publicCapacity ?? []).map((model) => [model.id, model]));
  const inventory = buildModelInventory(stats, aliases).map((item) => ({
    ...item,
    id: item.model.id,
    providers: item.model.providers,
    catalogModel: catalogByID.get(item.model.id),
    capacity: capacityByID.get(item.model.id),
  }));
  const filtered: { visible: ActiveModelInventory[]; deprecatedCount: number } = catalogModels
    ? filterServedCatalogModels(inventory, catalogModels, includeDeprecated)
    : { visible: inventory.map((item) => ({ ...item, catalogStatus: "active" })), deprecatedCount: 0 };
  const placements = filtered.visible.reduce((sum, item) => sum + item.model.providers, 0);
  return {
    capacityKnown,
    deprecatedCount: filtered.deprecatedCount,
    placements,
    models: filtered.visible.map((item) => ({
      ...item,
      sharePct: placements > 0 ? (item.model.providers / placements) * 100 : 0,
    })),
  };
}
