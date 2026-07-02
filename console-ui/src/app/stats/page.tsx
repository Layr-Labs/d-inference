"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";
import {
  Activity,
  CheckCircle2,
  Clock,
  Cpu,
  HardDrive,
  ShieldCheck,
  Shield,
  Layers,
  Loader2,
  RefreshCw,
  Globe2,
  MapPin,
  Search,
  Server,
  SlidersHorizontal,
  XCircle,
  Zap,
} from "lucide-react";
import { TopBar } from "@/components/TopBar";
import {
  catalogDataFromResponse,
  capacityModelsFromResponse,
  filterServedCatalogModels,
  type CapacityModelSummary,
  type CatalogAliasSummary,
  type CatalogDataSummary,
  type CatalogModelSummary,
} from "@/lib/stats-model-filter";
// Type-only import keeps pkijs/asn1js (~76 KB gz) out of First Load; the
// verifier is dynamically imported where it's used (perf F4).
import type {
  CertVerificationResult,
  VerificationStep,
} from "@/lib/cert-verify";
import { formatPower } from "@/lib/format-power";
import { activeNetworkPowerWatts } from "@/lib/network-power";
import {
  MarkerClusterLayer,
  WorldDotMatrix,
  ZoomableMapViewport,
  type MarkerDatum,
} from "@/components/stats/network-map";

const COORDINATOR_URL = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

interface CPUCores {
  total: number;
  performance: number;
  efficiency: number;
}

interface ProviderStats {
  id: string;
  chip: string;
  chip_family: string;
  chip_tier: string;
  machine_model: string;
  memory_gb: number;
  gpu_cores: number;
  cpu_cores: CPUCores;
  memory_bandwidth_gbs: number;
  status: string;
  trust_level: string;
  decode_tps: number;
  current_model?: string;
  models?: string[];
  requests_served: number;
  tokens_generated: number;
  attested?: boolean;
  mda_verified?: boolean;
  acme_verified?: boolean;
  runtime_verified?: boolean;
  certificate_available?: boolean;
  last_challenge_verified?: string;
  failed_challenges?: number;
  routable?: boolean;
}

interface ModelStats {
  id: string;
  providers: number;
}

interface ProviderLocationBucket {
  key: string;
  scope: "city" | "region" | "country" | string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
  providers: number;
  hardware_attested: number;
  gpu_cores: number;
  memory_gb: number;
  models?: string[];
}

interface RequestLocationBucket {
  key: string;
  scope: "city" | "region" | "country" | string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  providers: number;
}

interface FlowLocation {
  key: string;
  kind: "consumer" | "provider" | string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
}

interface RequestFlowBucket {
  key: string;
  from: FlowLocation;
  to: FlowLocation;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
}

interface TimeSeriesBucket {
  timestamp: string;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  active_providers: number;
}

interface NetworkUtilization {
  utilization: number;
  warm_utilization?: number;
  token_budget_utilization?: number;
  bottleneck_utilization?: number;
  bottleneck_model?: string;
  capacity_tps?: number;
  active_requests?: number;
  queued_requests?: number;
}

interface PlatformStats {
  total_requests: number;
  total_prompt_tokens: number;
  total_completion_tokens: number;
  total_tokens: number;
  avg_tokens_per_request: number;
  active_providers: number;
  total_gpu_cores: number;
  total_cpu_cores: number;
  total_memory_gb: number;
  total_bandwidth_gbs: number;
  network_capacity_tps: number;
  active_power_watts?: number;
  network_utilization?: NetworkUtilization;
  providers: ProviderStats[];
  models: ModelStats[];
  provider_locations?: ProviderLocationBucket[];
  provider_regions?: ProviderLocationBucket[];
  unknown_location_providers?: number;
  suppressed_city_location_providers?: number;
  location_privacy_min_providers?: number;
  request_locations?: RequestLocationBucket[];
  request_regions?: RequestLocationBucket[];
  request_flows?: RequestFlowBucket[];
  unknown_request_location_requests?: number;
  suppressed_request_city_requests?: number;
  request_location_privacy_min_requests?: number;
  time_series: TimeSeriesBucket[];
}

interface ProviderAttestation {
  provider_id: string;
  trust_level: string;
  status: string;
  serial_number?: string;
  se_public_key?: string;
  mda_verified?: boolean;
  acme_verified?: boolean;
  secure_enclave?: boolean;
  sip_enabled?: boolean;
  secure_boot_enabled?: boolean;
  authenticated_root_enabled?: boolean;
  system_volume_hash?: string;
  mda_cert_chain_b64?: string[];
  mda_serial?: string;
  mda_os_version?: string;
  mda_sepos_version?: string;
}

type NodeStatusFilter = "all" | "routable" | "serving" | "online" | "attention";
type NodeTrustFilter = "all" | "hardware" | "none";
type NodeSortKey = "capacity" | "requests" | "tokens" | "chip";

const GEMMA_PUBLIC_ID = "gemma-4-26b";
const GEMMA_QAT_ID = "gemma-4-26b-qat-4bit";
const GEMMA_ROLLBACK_ID = "gemma-4-26b-8bit";
const GEMMA_ROLLOUT_IDS = new Set([GEMMA_PUBLIC_ID, GEMMA_QAT_ID, GEMMA_ROLLBACK_ID]);

interface ModelInventory {
  model: ModelStats;
  providers: ProviderStats[];
  routable: number;
  hardware: number;
  gpuCores: number;
  memoryGB: number;
  sharePct: number;
}

type ActiveModelInventory = ModelInventory & {
  id: string;
  providers: number;
  catalogStatus?: string;
  catalogModel?: CatalogModelSummary;
  capacity?: CapacityModelSummary;
};

function formatNumber(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return n.toLocaleString();
}

function formatPercent(ratio: number): string {
  if (!Number.isFinite(ratio) || ratio < 0) return "—";
  const pct = ratio * 100;
  if (pct > 0 && pct < 1) return "<1%";
  return `${Math.round(pct)}%`;
}

function formatChartMinute(timestamp: string): string {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return "--:--";
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function normalizeTimeSeries(data: TimeSeriesBucket[], minutes = 30): TimeSeriesBucket[] {
  const byMinute = new Map<string, TimeSeriesBucket>();
  for (const bucket of data) {
    const date = new Date(bucket.timestamp);
    if (Number.isNaN(date.getTime())) continue;
    date.setSeconds(0, 0);
    byMinute.set(date.toISOString(), bucket);
  }

  const end = new Date();
  end.setSeconds(0, 0);
  return Array.from({ length: minutes }, (_, index) => {
    const date = new Date(end.getTime() - (minutes - 1 - index) * 60_000);
    const key = date.toISOString();
    const existing = byMinute.get(key);
    return existing ?? {
      timestamp: key,
      requests: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      active_providers: 0,
    };
  });
}

async function fetchModelCatalog(): Promise<CatalogDataSummary | null> {
  const urls = [
    "/api/models",
    `${COORDINATOR_URL}/v1/models/catalog?type=text&include_aliases=1`,
  ];

  for (const url of urls) {
    try {
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) continue;
      const catalog = catalogDataFromResponse(await res.json());
      if (catalog.models.length > 0) return catalog;
    } catch {
      // Keep stats usable if catalog lookup fails.
    }
  }

  return null;
}

async function fetchModelCapacity(): Promise<CapacityModelSummary[] | null> {
  const urls = [
    "/api/models/capacity",
    `${COORDINATOR_URL}/v1/models/capacity`,
  ];

  for (const url of urls) {
    try {
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) continue;
      const capacity = capacityModelsFromResponse(await res.json());
      if (capacity.length > 0) return capacity;
    } catch {
      // Keep stats usable if capacity lookup fails.
    }
  }

  return null;
}

function formatGB(value?: number): string | null {
  if (value === undefined) return null;
  return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)} GB`;
}

function formatLatency(ms?: number): string {
  if (ms === undefined) return "--";
  if (ms >= 1000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.round(ms)}ms`;
}

function formatDecimal(value?: number): string {
  if (value === undefined) return "--";
  return value >= 100 ? value.toFixed(0) : value.toFixed(1);
}

function formatTokenBudget(capacity?: CapacityModelSummary): string {
  if (!capacity || capacity.tokenBudgetTotal === undefined) return "--";
  if (capacity.tokenBudgetTotal <= 0) return "0";
  const remaining = capacity.tokenBudgetRemaining ?? 0;
  return `${Math.round((remaining / capacity.tokenBudgetTotal) * 100)}%`;
}

function StatusDot({ status }: { status: string }) {
  const color =
    status === "online" || status === "serving"
      ? "bg-accent-green"
      : status === "untrusted"
      ? "bg-accent-red"
      : "bg-accent-amber";
  return (
    <span className="relative flex h-2.5 w-2.5">
      {(status === "online" || status === "serving") && (
        <span className={`animate-ping absolute inline-flex h-full w-full rounded-full ${color} opacity-40`} />
      )}
      <span className={`relative inline-flex rounded-full h-2.5 w-2.5 ${color}`} />
    </span>
  );
}

function TrustBadge({ level }: { level: string }) {
  if (level === "hardware") {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-green/10 border border-accent-green/20 text-accent-green text-xs font-medium uppercase tracking-wider">
        <ShieldCheck size={10} />
        Hardware
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-bg-elevated border border-border-subtle text-text-tertiary text-xs font-medium uppercase tracking-wider">
      <Shield size={10} />
      None
    </span>
  );
}

// ---------------------------------------------------------------------------
// Big hero number
// ---------------------------------------------------------------------------
function HeroStat({
  value,
  label,
  sub,
}: {
  value: string;
  label: string;
  sub?: string;
}) {
  return (
    <div className="text-center">
      <p className="text-2xl sm:text-4xl md:text-5xl font-mono font-bold text-text-primary tracking-tighter">
        {value}
      </p>
      <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest mt-1">
        {label}
      </p>
      {sub && (
        <p className="text-xs font-mono text-text-tertiary mt-0.5">{sub}</p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Compact stat
// ---------------------------------------------------------------------------
function MiniStat({
  label,
  value,
  sub,
}: {
  label: string;
  value: string;
  sub?: string;
}) {
  return (
    <div className="rounded-xl border border-border-dim bg-bg-white px-4 py-3 shadow-sm">
      <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
        {label}
      </p>
      <p className="mt-1 text-xl font-mono font-bold text-text-primary">{value}</p>
      {sub && (
        <p className="text-xs font-mono text-text-tertiary mt-0.5">{sub}</p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Network Power -- realistic Apple Silicon draw, auto-scaled units
// ---------------------------------------------------------------------------
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

function publicCatalogModels(catalogModels: CatalogModelSummary[], aliases: CatalogAliasSummary[]): CatalogModelSummary[] {
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

function buildModelInventory(stats: PlatformStats, aliases: CatalogAliasSummary[] = []): ModelInventory[] {
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
        providers,
        routable: providers.filter(isProviderRoutable).length,
        hardware: providers.filter((provider) => provider.trust_level === "hardware").length,
        gpuCores: providers.reduce((sum, provider) => sum + provider.gpu_cores, 0),
        memoryGB: providers.reduce((sum, provider) => sum + provider.memory_gb, 0),
        sharePct: totalSlots > 0 ? (model.providers / totalSlots) * 100 : 0,
      };
    })
    .sort((a, b) => b.model.providers - a.model.providers || a.model.id.localeCompare(b.model.id));
}

function deprecatedModelLabel(status?: string): string | null {
  if (!status) return null;
  const normalized = status.toLowerCase();
  if (normalized === "deprecated") return "Deprecated";
  if (normalized === "retired") return "Retired";
  return null;
}

function ModelRow({
  item,
  maxProviders,
  rank,
}: {
  item: ActiveModelInventory;
  maxProviders: number;
  rank: number;
}) {
  const { model } = item;
  const pct = maxProviders > 0 ? (model.providers / maxProviders) * 100 : 0;
  const routablePct = model.providers > 0 ? (item.routable / model.providers) * 100 : 0;
  const isLeader = rank === 1;
  const statusLabel = deprecatedModelLabel(item.catalogStatus);
  const catalog = item.catalogModel;
  const capacity = item.capacity;
  const displayName = catalog?.displayName || shortModelName(model.id);
  const modelSize = formatGB(catalog?.sizeGB);
  const minRAM = formatGB(catalog?.minRAMGB);
  const queueValue = capacity
    ? `${(capacity.activeRequests ?? 0) + (capacity.queuedRequests ?? 0)}/${capacity.queueLimit ?? "--"}`
    : "--";
  const warmColdValue = capacity
    ? `${capacity.warmProviders ?? 0}/${capacity.coldProviders ?? 0}`
    : "--";

  return (
    <div
      className={`relative overflow-hidden rounded-xl border px-4 py-4 shadow-sm transition-colors ${
        isLeader
          ? "border-accent-brand/30 bg-[linear-gradient(135deg,var(--accent-brand-dim),var(--bg-secondary)_42%,var(--bg-primary))]"
          : "border-border-dim bg-bg-secondary"
      }`}
    >
      <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
        <div className="flex min-w-0 items-start gap-3">
          <div
            className={`relative mt-0.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-lg border ${
              isLeader
                ? "border-accent-brand/40 bg-accent-brand text-bg-primary"
                : "border-accent-brand/20 bg-accent-brand/10 text-accent-brand"
            }`}
          >
            <Layers size={16} />
            <span
              className={`absolute -right-1.5 -top-1.5 rounded-full border px-1.5 py-0.5 text-[9px] font-mono font-bold ${
                isLeader
                  ? "border-accent-brand bg-bg-primary text-accent-brand"
                  : "border-border-dim bg-bg-primary text-text-tertiary"
              }`}
            >
              {rank}
            </span>
          </div>
          <div className="min-w-0 space-y-2">
            <div>
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <p className="truncate text-base font-mono font-semibold text-text-primary">
                  {displayName}
                </p>
                {statusLabel && (
                  <span className="shrink-0 rounded-full border border-accent-amber/30 bg-accent-amber-dim px-2 py-0.5 text-[9px] font-mono uppercase tracking-wider text-accent-amber">
                    {statusLabel}
                  </span>
                )}
              </div>
              <p className="truncate text-xs font-mono text-text-tertiary">{model.id}</p>
            </div>
            <div className="flex flex-wrap gap-1.5">
              {catalog?.family && <ModelPill label={catalog.family} />}
              {catalog?.quantization && <ModelPill label={catalog.quantization} />}
              {modelSize && <ModelPill label={modelSize} />}
              {minRAM && <ModelPill label={`${minRAM} min`} />}
              {catalog?.maxContextLength && <ModelPill label={`${formatNumber(catalog.maxContextLength)} ctx`} />}
              <ModelPill label={`${formatNumber(item.gpuCores)} GPU`} />
              <ModelPill label={`${formatNumber(item.memoryGB)} GB RAM`} />
            </div>
          </div>
        </div>

        <div className="grid grid-cols-4 gap-2 text-right md:min-w-[330px]">
          <ModelMiniMetric label="Nodes" value={model.providers.toString()} />
          <ModelMiniMetric label="Routable" value={item.routable.toString()} tone="green" />
          <ModelMiniMetric label="Hardware" value={item.hardware.toString()} />
          <ModelMiniMetric label="Share" value={`${item.sharePct.toFixed(0)}%`} />
        </div>
      </div>

      {capacity && (
        <div className="mt-4 grid grid-cols-2 gap-2 md:grid-cols-5">
          <CapacityMetric label="Capacity TPS" value={formatDecimal(capacity.aggregateTPS)} />
          <CapacityMetric label="TTFT Est." value={formatLatency(capacity.estimatedTTFTMS)} />
          <CapacityMetric label="Queue" value={queueValue} />
          <CapacityMetric label="Warm/Cold" value={warmColdValue} />
          <CapacityMetric
            label="Token Budget"
            value={formatTokenBudget(capacity)}
            tone={capacity.canAccept ? "green" : "amber"}
          />
        </div>
      )}

      <div className="mt-4 space-y-2">
        <div className="flex items-center justify-between gap-3 text-[11px] font-mono text-text-tertiary">
          <span>{item.sharePct.toFixed(0)}% of visible model slots</span>
          <span>{Math.round(routablePct)}% routable coverage</span>
        </div>
        <div className="relative h-2.5 overflow-hidden rounded-full bg-bg-elevated">
          <div
            className="absolute inset-y-0 left-0 rounded-full bg-accent-brand/75"
            style={{ width: `${Math.max(4, pct)}%` }}
          />
          <div
            className="absolute inset-y-0 left-0 rounded-full bg-accent-green/70"
            style={{ width: `${Math.max(item.routable > 0 ? 4 : 0, (pct * routablePct) / 100)}%` }}
          />
          <div className="absolute inset-0 bg-[linear-gradient(90deg,transparent,rgba(255,255,255,0.22),transparent)] opacity-50" />
        </div>
      </div>
    </div>
  );
}

function ModelMiniMetric({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: "green" | "muted";
}) {
  const valueClass =
    tone === "green"
      ? "text-accent-green"
      : tone === "muted"
        ? "text-text-tertiary"
        : "text-text-primary";

  return (
    <div className="rounded-lg border border-border-dim bg-bg-primary/60 px-2.5 py-2">
      <p className={`text-sm font-mono font-bold ${valueClass}`}>{value}</p>
      <p className="mt-0.5 text-[9px] font-mono uppercase tracking-wider text-text-tertiary">
        {label}
      </p>
    </div>
  );
}

function CapacityMetric({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: "green" | "amber";
}) {
  let toneClass = "text-text-primary";
  if (tone === "green") {
    toneClass = "text-accent-green";
  } else if (tone === "amber") {
    toneClass = "text-accent-amber";
  }

  return (
    <div className="rounded-lg border border-border-dim bg-bg-primary/60 px-2.5 py-2">
      <p className={`text-sm font-mono font-bold ${toneClass}`}>{value}</p>
      <p className="mt-0.5 text-[9px] font-mono uppercase tracking-wider text-text-tertiary">
        {label}
      </p>
    </div>
  );
}

function ModelPill({ label }: { label: string }) {
  return (
    <span className="rounded-md border border-border-dim bg-bg-primary/70 px-2 py-1 text-[10px] font-mono text-text-tertiary">
      {label}
    </span>
  );
}

function ModelHeaderMetric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-lg font-mono font-bold text-text-primary">{value}</p>
      <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
        {label}
      </p>
    </div>
  );
}

function ActiveModelsSection({
  stats,
  catalogData,
  capacityModels,
}: {
  stats: PlatformStats;
  catalogData: CatalogDataSummary | null;
  capacityModels: CapacityModelSummary[] | null;
}) {
  const [showDeprecatedModels, setShowDeprecatedModels] = useState(false);
  const aliases = catalogData?.aliases ?? [];
  const catalogModels = catalogData ? publicCatalogModels(catalogData.models, aliases) : null;
  const publicCapacity = publicCapacityModels(capacityModels, aliases);
  const inventory = buildModelInventory(stats, aliases);
  const catalogByID = new Map((catalogModels ?? []).map((model) => [model.id, model]));
  const capacityByID = new Map((publicCapacity ?? []).map((model) => [model.id, model]));
  const servedInventory = inventory.map((item) => ({
    ...item,
    id: item.model.id,
    providers: item.model.providers,
    catalogModel: catalogByID.get(item.model.id),
    capacity: capacityByID.get(item.model.id),
  }));
  const filtered = catalogModels
    ? filterServedCatalogModels(servedInventory, catalogModels, showDeprecatedModels)
    : {
      visible: servedInventory.map((item) => ({ ...item, catalogStatus: "active" })),
      catalogServedCount: servedInventory.length,
      deprecatedCount: 0,
    };
  const filteredSlots = filtered.visible.reduce((sum, item) => sum + item.model.providers, 0);
  const visibleInventory = filtered.visible.map((item) => ({
    ...item,
    sharePct: filteredSlots > 0 ? (item.model.providers / filteredSlots) * 100 : 0,
  }));
  const maxProviders = Math.max(...visibleInventory.map((item) => item.model.providers), 1);
  const totalSlots = filteredSlots;
  const routableSlots = visibleInventory.reduce((sum, item) => sum + item.routable, 0);

  return (
    <section className="rounded-xl border border-border-dim bg-bg-white p-5 shadow-sm">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-3">
          <div className="flex h-9 w-9 items-center justify-center rounded-lg border border-accent-brand/20 bg-accent-brand/10 text-accent-brand">
            <Layers size={17} />
          </div>
          <div>
            <h3 className="text-sm font-semibold text-text-primary">
              Active Models
            </h3>
            <p className="mt-1 text-xs text-text-tertiary">
              Catalog metadata, live capacity, and trusted node coverage
            </p>
          </div>
        </div>
        <div className="flex flex-col items-start gap-3 sm:items-end">
          {filtered.deprecatedCount > 0 && (
            <label className="flex cursor-pointer items-center gap-2 rounded-lg border border-border-dim bg-bg-secondary px-3 py-2 text-xs font-mono text-text-secondary transition-colors hover:bg-bg-hover">
              <input
                type="checkbox"
                className="sr-only"
                checked={showDeprecatedModels}
                onChange={(event) => setShowDeprecatedModels(event.target.checked)}
                aria-label="Show deprecated models"
              />
              <span
                className={`relative h-5 w-9 rounded-full transition-colors ${
                  showDeprecatedModels ? "bg-accent-brand" : "bg-bg-elevated"
                }`}
                aria-hidden="true"
              >
                <span
                  className={`absolute top-0.5 h-4 w-4 rounded-full bg-bg-primary shadow-sm transition-transform ${
                    showDeprecatedModels ? "translate-x-4" : "translate-x-0.5"
                  }`}
                />
              </span>
              <span>Show deprecated ({filtered.deprecatedCount})</span>
            </label>
          )}
          <div className="grid grid-cols-3 gap-2 text-right sm:min-w-[250px]">
            <ModelHeaderMetric label="Models" value={visibleInventory.length.toString()} />
            <ModelHeaderMetric label="Slots" value={totalSlots.toString()} />
            <ModelHeaderMetric label="Routable Slots" value={routableSlots.toString()} />
          </div>
        </div>
      </div>

      <div className="mt-4 grid grid-cols-1 gap-3 lg:grid-cols-[1.2fr_0.8fr]">
        <div className="space-y-3">
          {visibleInventory.length === 0 ? (
            <div className="rounded-xl border border-dashed border-border-dim bg-bg-secondary px-4 py-5 text-sm text-text-tertiary">
              No currently served catalog models.
            </div>
          ) : (
            visibleInventory.map((item, index) => (
              <ModelRow
                key={item.model.id}
                item={item}
                maxProviders={maxProviders}
                rank={index + 1}
              />
            ))
          )}
        </div>
        <div className="rounded-xl border border-border-dim bg-bg-secondary p-4">
          <div className="flex items-center justify-between gap-3">
            <p className="text-xs font-mono uppercase tracking-wider text-text-tertiary">
              Fleet Mix
            </p>
            <p className="text-xs font-mono text-text-tertiary">
              {routableSlots}/{totalSlots} routable
            </p>
          </div>
          <div className="mt-4 space-y-3">
            {visibleInventory.length === 0 ? (
              <p className="text-sm text-text-tertiary">
                Deprecated provider-advertised models are hidden.
              </p>
            ) : (
              visibleInventory.map((item) => (
                <div key={`mix-${item.model.id}`}>
                  <div className="flex items-center justify-between gap-3 text-xs">
                    <p className="truncate font-mono text-text-secondary">
                      {shortModelName(item.model.id)}
                    </p>
                    <p className="shrink-0 font-mono font-semibold text-text-primary">
                      {item.sharePct.toFixed(0)}%
                    </p>
                  </div>
                  <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-bg-elevated">
                    <div
                      className="h-full rounded-full bg-accent-brand/70"
                      style={{ width: `${Math.max(3, item.sharePct)}%` }}
                    />
                  </div>
                </div>
              ))
            )}
          </div>
          <div className="mt-5 rounded-lg border border-accent-green/20 bg-accent-green/10 px-3 py-2">
            <div className="flex items-center justify-between gap-3">
              <span className="text-xs font-mono text-accent-green">Routable coverage</span>
              <span className="text-sm font-mono font-bold text-accent-green">
                {totalSlots > 0 ? Math.round((routableSlots / totalSlots) * 100) : 0}%
              </span>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function formatPlace(bucket: {
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
}): string {
  if (bucket.city) {
    return [bucket.city, bucket.region_code || bucket.region, bucket.country_code]
      .filter(Boolean)
      .join(", ");
  }
  return [bucket.region, bucket.country || bucket.country_code]
    .filter(Boolean)
    .join(", ");
}

function shortModelName(id: string): string {
  return id.split("/").pop()?.replace(/-/g, " ") || id;
}

function chipRank(chip: string): number {
  const normalized = chip.toLowerCase();
  if (normalized.includes("ultra")) return 4;
  if (normalized.includes("max")) return 3;
  if (normalized.includes("pro")) return 2;
  return 1;
}

function providerCapacityScore(provider: ProviderStats): number {
  return (
    provider.memory_bandwidth_gbs * 3 +
    provider.gpu_cores * 12 +
    provider.memory_gb * 1.5 +
    chipRank(provider.chip) * 100
  );
}

function compareProviders(a: ProviderStats, b: ProviderStats, sortKey: NodeSortKey) {
  if (sortKey === "requests") {
    return b.requests_served - a.requests_served || a.id.localeCompare(b.id);
  }
  if (sortKey === "tokens") {
    return b.tokens_generated - a.tokens_generated || a.id.localeCompare(b.id);
  }
  if (sortKey === "chip") {
    return a.chip.localeCompare(b.chip) || a.id.localeCompare(b.id);
  }
  return providerCapacityScore(b) - providerCapacityScore(a) || a.id.localeCompare(b.id);
}

function compactId(id: string): string {
  if (id.length <= 14) return id;
  return `${id.slice(0, 8)}...${id.slice(-4)}`;
}

function maskSerial(serial?: string): string {
  if (!serial) return "";
  if (serial.length <= 7) return serial;
  return `${serial.slice(0, 4)}...${serial.slice(-3)}`;
}

function verificationLabel(provider: ProviderStats): string {
  if (isProviderRoutable(provider)) return "Routable";
  if (provider.mda_verified) return "Apple MDA";
  if (provider.acme_verified) return "ACME bound";
  if (provider.runtime_verified && provider.trust_level === "hardware") return "Challenge fresh";
  if (provider.trust_level === "hardware") return "Hardware";
  return "Unverified";
}

function hasFreshChallenge(iso?: string): boolean {
  if (!iso) return false;
  const then = new Date(iso).getTime();
  if (!Number.isFinite(then)) return false;
  return Date.now() - then <= 6 * 60 * 1000;
}

function isProviderRoutable(provider: ProviderStats): boolean {
  if (typeof provider.routable === "boolean") {
    return provider.routable;
  }
  const statusOK = provider.status === "online" || provider.status === "serving";
  const trustOK = provider.trust_level === "hardware";
  const runtimeOK = provider.runtime_verified !== false;
  const certificateOK = provider.certificate_available || provider.mda_verified;
  return statusOK && trustOK && runtimeOK && hasFreshChallenge(provider.last_challenge_verified) && Boolean(certificateOK);
}

function relativeChallengeLabel(iso?: string): string {
  if (iso === undefined) return "not published";
  if (!iso) return "not seen";
  const then = new Date(iso).getTime();
  if (!Number.isFinite(then)) return "not seen";
  const seconds = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  return `${hours}h ago`;
}

function projectedPoint(bucket: { latitude?: number; longitude?: number }) {
  const lat = bucket.latitude ?? 0;
  const lon = bucket.longitude ?? 0;
  return {
    x: Math.min(96, Math.max(4, ((lon + 180) / 360) * 100)),
    y: Math.min(90, Math.max(8, ((90 - lat) / 180) * 100)),
  };
}

function hasCoordinates(bucket: { latitude?: number; longitude?: number }): boolean {
  return typeof bucket.latitude === "number" && typeof bucket.longitude === "number";
}

function locationBucketKey(bucket: {
  key?: string;
  city?: string;
  region_code?: string;
  region?: string;
  country_code?: string;
}): string {
  if (bucket.key) {
    return bucket.key.toLowerCase();
  }
  return [
    bucket.country_code,
    bucket.region_code || bucket.region,
    bucket.city,
  ]
    .filter(Boolean)
    .join("|")
    .toLowerCase();
}

function flowPath(from: { latitude?: number; longitude?: number }, to: { latitude?: number; longitude?: number }) {
  const start = projectedPoint(from);
  const end = projectedPoint(to);
  const sx = start.x * 10;
  const sy = start.y * 5;
  const ex = end.x * 10;
  const ey = end.y * 5;
  const distance = Math.hypot(ex - sx, ey - sy);
  const lift = Math.min(110, Math.max(34, distance * 0.16));
  const cx = (sx + ex) / 2;
  const cy = Math.min(sy, ey) - lift;
  return `M ${sx.toFixed(1)} ${sy.toFixed(1)} Q ${cx.toFixed(1)} ${cy.toFixed(1)} ${ex.toFixed(1)} ${ey.toFixed(1)}`;
}

function ProviderGeography({ stats }: { stats: PlatformStats }) {
  const cityBuckets = stats.provider_locations ?? [];
  const regionBuckets = stats.provider_regions ?? [];
  const requestBuckets = stats.request_locations ?? [];
  const requestFlows = (stats.request_flows ?? [])
    .filter((flow) => hasCoordinates(flow.from) && hasCoordinates(flow.to))
    .slice(0, 18);
  const unknown = stats.unknown_location_providers ?? 0;
  const suppressed = stats.suppressed_city_location_providers ?? 0;
  const privacyMin = stats.location_privacy_min_providers ?? 2;
  const knownProviders = regionBuckets.reduce((sum, bucket) => sum + bucket.providers, 0);
  const providerCityKeys = new Set(cityBuckets.map(locationBucketKey));
  const providerRegionKeys = new Set(regionBuckets.map(locationBucketKey));
  const hasLocalProvider = (bucket: RequestLocationBucket) => {
    const cityKey = locationBucketKey(bucket);
    const regionKey = [
      bucket.country_code,
      bucket.region_code || bucket.region,
    ]
      .filter(Boolean)
      .join("|")
      .toLowerCase();
    return providerCityKeys.has(cityKey) || providerRegionKeys.has(regionKey);
  };
  const plotted = cityBuckets.filter(hasCoordinates);
  const fallbackPlotted = plotted.length > 0
    ? plotted
    : regionBuckets.filter(hasCoordinates);
  const providerMarkers: MarkerDatum[] = fallbackPlotted.map((bucket) => {
    const point = projectedPoint(bucket);
    const attestedPct = bucket.providers > 0
      ? Math.round((bucket.hardware_attested / bucket.providers) * 100)
      : 0;
    return {
      key: bucket.key,
      xPct: point.x,
      yPct: point.y,
      nodes: bucket.providers,
      label: formatPlace(bucket),
      detail: `${bucket.providers} nodes / ${attestedPct}% attested / ${bucket.gpu_cores} GPU cores`,
    };
  });
  const sortedRequestBuckets = requestBuckets
    .slice()
    .sort((a, b) => b.requests - a.requests);
  const consumerPlotted = sortedRequestBuckets.filter(hasCoordinates).slice(0, 14);
  const demandOnlyOrigins = sortedRequestBuckets.filter((bucket) => !hasLocalProvider(bucket));
  const demandOnlyRequests = demandOnlyOrigins.reduce((sum, bucket) => sum + bucket.requests, 0);
  const topCities = cityBuckets.slice(0, 4);
  const recentBuckets = normalizeTimeSeries(stats.time_series);
  const recentRequests = recentBuckets.reduce((sum, bucket) => sum + bucket.requests, 0);
  const recentTokens = recentBuckets.reduce(
    (sum, bucket) => sum + bucket.prompt_tokens + bucket.completion_tokens,
    0,
  );
  const peakRequests = Math.max(...recentBuckets.map((bucket) => bucket.requests), 0);
  const routableProviders = stats.providers.filter(isProviderRoutable).length;
  const hardwareProviders = stats.providers.filter((provider) => provider.trust_level === "hardware").length;
  const certificateProviders = stats.providers.filter(
    (provider) => provider.certificate_available || provider.mda_verified,
  ).length;
  const networkDecodeTPS = stats.providers.reduce((sum, provider) => sum + provider.decode_tps, 0);
  const networkTPS = stats.network_capacity_tps || networkDecodeTPS;
  const unknownProviderLabel = unknown === 1 ? "provider" : "providers";
  const emptyLocationMessage = unknown > 0
    ? `${unknown} ${unknownProviderLabel} online without a resolved location`
    : "No resolved provider locations yet";

  return (
    <section className="bg-bg-white rounded-xl p-5 sm:p-6 shadow-sm space-y-5">
      <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <Globe2 size={16} className="text-accent-brand" />
            <h2 className="text-sm font-semibold text-text-primary">
              Live Network Flow
            </h2>
          </div>
          <p className="text-xs text-text-tertiary mt-1">
            Privacy-bucketed consumer demand flowing into online provider capacity
          </p>
        </div>
        <div className="grid grid-cols-3 gap-2 text-right sm:min-w-[260px]">
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">
              {knownProviders}
            </p>
            <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
              Providers
            </p>
          </div>
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">
              {formatNumber(demandOnlyRequests)}
            </p>
            <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
              Demand-Only
            </p>
          </div>
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">
              {requestFlows.length}
            </p>
            <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
              Routes
            </p>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 items-start gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
        <ZoomableMapViewport
          className="relative aspect-[2/1] min-h-[260px] overflow-hidden rounded-xl border border-border-dim shadow-inner"
          style={{
            background:
              "radial-gradient(115% 78% at 50% -10%, color-mix(in srgb, var(--accent-brand) 11%, transparent), transparent 55%), radial-gradient(85% 70% at 50% 118%, color-mix(in srgb, var(--accent-green) 7%, transparent), transparent 52%), linear-gradient(180deg, var(--bg-primary), var(--bg-secondary))",
            boxShadow:
              "inset 0 1px 0 color-mix(in srgb, white 45%, transparent), inset 0 0 0 1px color-mix(in srgb, var(--text-primary) 5%, transparent), inset 0 0 72px 6px color-mix(in srgb, var(--text-primary) 13%, transparent)",
          }}
          interactive={fallbackPlotted.length > 0}
          overlay={
            <div className="pointer-events-none absolute left-3 top-3 z-30 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-border-dim bg-bg-primary/85 px-3 py-1.5 shadow-sm backdrop-blur">
              <span className="flex items-center gap-1.5 text-[10px] font-mono uppercase tracking-wide text-text-secondary">
                <span
                  className="h-2 w-2 rounded-full"
                  style={{ background: "radial-gradient(circle at 30% 28%, color-mix(in srgb, white 30%, var(--accent-brand)), var(--accent-brand))" }}
                />
                providers
              </span>
              <span className="flex items-center gap-1.5 text-[10px] font-mono uppercase tracking-wide text-text-secondary">
                <span className="h-2 w-2 rounded-full bg-accent-green" />
                consumers
              </span>
              <span className="flex items-center gap-1.5 text-[10px] font-mono uppercase tracking-wide text-text-secondary">
                <span className="h-2 w-2 rounded-full border-[1.5px] border-accent-amber" />
                demand
              </span>
            </div>
          }
        >
          {(ctx) => (
            <>
              <WorldDotMatrix className="absolute inset-0 h-full w-full" preserveAspectRatio="xMidYMid meet" />
              <svg
                className="absolute inset-0 h-full w-full"
                viewBox="0 0 1000 500"
                preserveAspectRatio="xMidYMid meet"
                aria-hidden="true"
                style={{ pointerEvents: "none" }}
              >
                <defs>
                  <linearGradient id="flow-stroke" x1="0" y1="0" x2="1" y2="0">
                    <stop offset="0%" stopColor="var(--accent-brand)" stopOpacity="0.04" />
                    <stop offset="50%" stopColor="var(--accent-brand)" stopOpacity="0.5" />
                    <stop offset="100%" stopColor="var(--accent-green)" stopOpacity="0.04" />
                  </linearGradient>
                  <radialGradient id="consumer-dot-fill" cx="35%" cy="30%" r="75%">
                    <stop offset="0%" stopColor="color-mix(in srgb, white 50%, var(--accent-green))" />
                    <stop offset="62%" stopColor="var(--accent-green)" />
                    <stop offset="100%" stopColor="color-mix(in srgb, black 14%, var(--accent-green))" />
                  </radialGradient>
                  <radialGradient id="demand-dot-fill" cx="35%" cy="30%" r="75%">
                    <stop offset="0%" stopColor="color-mix(in srgb, white 52%, var(--accent-amber))" />
                    <stop offset="62%" stopColor="var(--accent-amber)" />
                    <stop offset="100%" stopColor="color-mix(in srgb, black 14%, var(--accent-amber))" />
                  </radialGradient>
                </defs>
                <g fill="none" strokeLinecap="round">
                  {requestFlows.map((flow) => {
                    const path = flowPath(flow.from, flow.to);
                    const width = Math.min(2.2, 0.7 + Math.sqrt(flow.requests) / 44);
                    return (
                      <path
                        key={flow.key}
                        d={path}
                        stroke="url(#flow-stroke)"
                        strokeWidth={width}
                        vectorEffect="non-scaling-stroke"
                      />
                    );
                  })}
                </g>
                <g>
                  {requestFlows.slice(0, 10).map((flow, index) => {
                    const path = flowPath(flow.from, flow.to);
                    return (
                      <path
                        key={`${flow.key}-pulse`}
                        className="network-flow-ping"
                        d={path}
                        fill="none"
                        stroke={index % 3 === 0 ? "var(--accent-brand)" : "var(--accent-green)"}
                        strokeWidth={index < 4 ? 2.1 : 1.5}
                        strokeLinecap="round"
                        strokeDasharray="0.1 46"
                        strokeOpacity="0.88"
                        vectorEffect="non-scaling-stroke"
                        style={{
                          animationDuration: `${3.6 + (index % 5) * 0.4}s`,
                          animationDelay: `${index * -0.3}s`,
                        }}
                      />
                    );
                  })}
                </g>
                <g>
                  {consumerPlotted.map((bucket) => {
                    const point = projectedPoint(bucket);
                    const demandOnly = !hasLocalProvider(bucket);
                    const r = Math.min(5.5, 2.2 + Math.sqrt(bucket.requests) / 34);
                    return (
                      <g
                        key={`consumer-${bucket.key}`}
                        transform={`translate(${point.x * 10} ${point.y * 5}) scale(${1 / ctx.scale})`}
                      >
                        <circle
                          r={r + (demandOnly ? 4 : 2.6)}
                          fill={demandOnly ? "var(--accent-amber)" : "var(--accent-green)"}
                          opacity={demandOnly ? "0.16" : "0.12"}
                        />
                        {demandOnly && (
                          <circle
                            r={r + 2}
                            fill="none"
                            stroke="var(--accent-amber)"
                            strokeDasharray="2 3.5"
                            strokeOpacity="0.55"
                            strokeWidth="1"
                          />
                        )}
                        <circle
                          r={r}
                          fill={demandOnly ? "url(#demand-dot-fill)" : "url(#consumer-dot-fill)"}
                          stroke="var(--bg-primary)"
                          strokeWidth="1.3"
                        />
                      </g>
                    );
                  })}
                </g>
              </svg>

              {fallbackPlotted.length === 0 ? (
                <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 px-8 text-center">
                  <MapPin size={22} className="text-text-tertiary" />
                  <div className="relative z-10 rounded-md border border-border-dim bg-bg-secondary px-4 py-2 shadow-sm">
                    <p className="text-sm font-semibold text-text-secondary">
                      Geography will appear as providers reconnect
                    </p>
                    <p className="text-xs text-text-tertiary mt-1">
                      {emptyLocationMessage}
                    </p>
                  </div>
                </div>
              ) : (
                <MarkerClusterLayer
                  markers={providerMarkers}
                  scale={ctx.scale}
                  width={ctx.width}
                  height={ctx.height}
                  onZoomToPercent={ctx.zoomToPercent}
                />
              )}
            </>
          )}
        </ZoomableMapViewport>

        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <FlowMetric label="30m requests" value={formatNumber(recentRequests)} sub={`${formatNumber(peakRequests)} peak/min`} />
            <FlowMetric label="30m tokens" value={formatNumber(recentTokens)} sub={`${formatNumber(Math.round(recentTokens / recentBuckets.length))}/min avg`} />
            <FlowMetric label="Routable nodes" value={routableProviders.toString()} sub={`${hardwareProviders} hardware-trusted`} />
            <FlowMetric
              label="Model TPS"
              value={networkTPS > 0 ? formatNumber(Math.round(networkTPS)) : "--"}
              sub={networkTPS > 0 ? "reported capacity" : "benchmarks pending"}
            />
            <FlowMetric label="Certificates" value={certificateProviders.toString()} sub="public proof ready" />
            <FlowMetric label="Remote demand" value={formatNumber(demandOnlyRequests)} sub={`${requestFlows.length} active routes`} />
          </div>

          <div>
            <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              Provider Capacity
            </h3>
            <div className="space-y-3">
              {topCities.length === 0 ? (
                <p className="text-sm text-text-tertiary">
                  City buckets need at least {privacyMin} providers.
                </p>
              ) : (
                topCities.map((bucket) => (
                  <LocationRow key={bucket.key} bucket={bucket} compact />
                ))
              )}
            </div>
          </div>
        </div>
      </div>

      {(unknown > 0 || suppressed > 0) && (
        <p className="text-xs text-text-tertiary">
          {unknown > 0 ? `${unknown} unknown` : ""}
          {unknown > 0 && suppressed > 0 ? " / " : ""}
          {suppressed > 0 ? `${suppressed} city-level hidden by privacy floor` : ""}
        </p>
      )}
    </section>
  );
}

function FlowMetric({
  label,
  value,
  sub,
}: {
  label: string;
  value: string;
  sub: string;
}) {
  return (
    <div className="rounded-lg border border-border-dim bg-bg-secondary px-3 py-2.5">
      <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
        {label}
      </p>
      <p className="mt-1 text-lg font-mono font-bold text-text-primary">{value}</p>
      <p className="mt-0.5 truncate text-[11px] font-mono text-text-tertiary">{sub}</p>
    </div>
  );
}

function LocationRow({
  bucket,
  compact,
}: {
  bucket: ProviderLocationBucket;
  compact?: boolean;
}) {
  const attestedPct = bucket.providers > 0
    ? Math.round((bucket.hardware_attested / bucket.providers) * 100)
    : 0;
  const model = bucket.models?.[0];

  return (
    <div className="border-b border-border-dim pb-3 last:border-b-0 last:pb-0">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-sm font-semibold text-text-primary truncate">
            {formatPlace(bucket)}
          </p>
          {!compact && model && (
            <p className="text-xs font-mono text-text-tertiary truncate mt-0.5">
              {shortModelName(model)}
            </p>
          )}
        </div>
        <div className="text-right shrink-0">
          <p className="text-sm font-mono font-bold text-text-primary">
            {bucket.providers}
          </p>
          <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
            nodes
          </p>
        </div>
      </div>
      <div className="mt-2 flex items-center gap-2 text-[11px] font-mono text-text-tertiary">
        <span>{attestedPct}% attested</span>
        <span className="text-border-subtle">/</span>
        <span>{bucket.gpu_cores} GPU</span>
        <span className="text-border-subtle">/</span>
        <span>{formatNumber(bucket.memory_gb)} GB RAM</span>
      </div>
    </div>
  );
}

function RequestGeography({ stats }: { stats: PlatformStats }) {
  const cityBuckets = stats.request_locations ?? [];
  const regionBuckets = stats.request_regions ?? [];
  const unknown = stats.unknown_request_location_requests ?? 0;
  const suppressed = stats.suppressed_request_city_requests ?? 0;
  const privacyMin = stats.request_location_privacy_min_requests ?? 5;
  const plotted = cityBuckets.filter(hasCoordinates);
  const fallbackPlotted = plotted.length > 0
    ? plotted
    : regionBuckets.filter(hasCoordinates);
  const totalRequests = regionBuckets.reduce((sum, bucket) => sum + bucket.requests, 0);
  const topCities = cityBuckets.slice(0, 6);
  const topRegions = regionBuckets.slice(0, 6);

  return (
    <section className="bg-bg-white rounded-xl p-5 sm:p-6 shadow-sm space-y-5">
      <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <MapPin size={16} className="text-accent-brand" />
            <h2 className="text-sm font-semibold text-text-primary">
              Request Geography
            </h2>
          </div>
          <p className="text-xs text-text-tertiary mt-1">
            Privacy-bucketed demand origins from the last 24 hours
          </p>
        </div>
        <div className="grid grid-cols-3 gap-2 text-right sm:min-w-[260px]">
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">
              {formatNumber(totalRequests)}
            </p>
            <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
              Requests
            </p>
          </div>
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">
              {cityBuckets.length}
            </p>
            <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
              Cities
            </p>
          </div>
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">
              {regionBuckets.length}
            </p>
            <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
              Regions
            </p>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_320px] gap-5">
        <div
          className="relative aspect-[2/1] min-h-[260px] overflow-hidden rounded-lg border border-border-dim shadow-inner"
          style={{
            background:
              "radial-gradient(110% 80% at 50% -8%, color-mix(in srgb, var(--accent-green) 9%, transparent), transparent 55%), linear-gradient(180deg, var(--bg-primary), var(--bg-secondary))",
            boxShadow:
              "inset 0 1px 0 color-mix(in srgb, white 45%, transparent), inset 0 0 64px 6px color-mix(in srgb, var(--text-primary) 12%, transparent)",
          }}
        >
          <WorldDotMatrix className="absolute inset-0 h-full w-full" preserveAspectRatio="xMidYMid meet" />

          {fallbackPlotted.length === 0 ? (
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 px-8 text-center">
              <MapPin size={22} className="text-text-tertiary" />
              <div className="relative z-10 rounded-md border border-border-dim bg-bg-secondary px-4 py-2 shadow-sm">
                <p className="text-sm font-semibold text-text-secondary">
                  Request origins will appear after deployment
                </p>
                <p className="text-xs text-text-tertiary mt-1">
                  City buckets need at least {privacyMin} requests.
                </p>
              </div>
            </div>
          ) : (
            fallbackPlotted.map((bucket) => {
              const point = projectedPoint(bucket);
              const size = Math.min(34, 8 + Math.sqrt(bucket.requests) * 4);
              return (
                <div
                  key={bucket.key}
                  className="group absolute -translate-x-1/2 -translate-y-1/2"
                  style={{ left: `${point.x}%`, top: `${point.y}%` }}
                >
                  <div
                    className="relative rounded-full border-2 border-bg-primary bg-accent-green shadow-lg shadow-black/10"
                    style={{
                      width: `${size}px`,
                      height: `${size}px`,
                      boxShadow: `0 0 0 ${Math.max(5, Math.round(size / 3))}px color-mix(in srgb, var(--accent-green) 15%, transparent), 0 10px 28px color-mix(in srgb, var(--accent-green) 22%, transparent)`,
                    }}
                  >
                    <span className="absolute inset-[22%] rounded-full bg-white/20" />
                  </div>
                  <div className="absolute left-1/2 bottom-full mb-3 hidden -translate-x-1/2 group-hover:block z-20">
                    <div className="min-w-[190px] rounded-lg bg-text-primary px-3 py-2 text-bg-primary shadow-lg">
                      <p className="text-xs font-semibold">{formatPlace(bucket)}</p>
                      <p className="text-[11px] font-mono opacity-80 mt-1">
                        {formatNumber(bucket.requests)} requests / {formatNumber(bucket.prompt_tokens + bucket.completion_tokens)} tokens
                      </p>
                    </div>
                  </div>
                </div>
              );
            })
          )}
        </div>

        <div className="space-y-5">
          <div>
            <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              Top Origins
            </h3>
            <div className="space-y-3">
              {topCities.length === 0 ? (
                <p className="text-sm text-text-tertiary">
                  No city-level demand buckets yet.
                </p>
              ) : (
                topCities.map((bucket) => (
                  <RequestLocationRow key={bucket.key} bucket={bucket} />
                ))
              )}
            </div>
          </div>

          <div>
            <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              Top Regions
            </h3>
            <div className="space-y-3">
              {topRegions.length === 0 ? (
                <p className="text-sm text-text-tertiary">No demand regions resolved yet.</p>
              ) : (
                topRegions.map((bucket) => (
                  <RequestLocationRow key={bucket.key} bucket={bucket} compact />
                ))
              )}
            </div>
          </div>
        </div>
      </div>

      {(unknown > 0 || suppressed > 0) && (
        <p className="text-xs text-text-tertiary">
          {unknown > 0 ? `${formatNumber(unknown)} unknown requests` : ""}
          {unknown > 0 && suppressed > 0 ? " / " : ""}
          {suppressed > 0 ? `${formatNumber(suppressed)} hidden by privacy floor` : ""}
        </p>
      )}
    </section>
  );
}

function RequestLocationRow({
  bucket,
  compact,
  demandOnly,
}: {
  bucket: RequestLocationBucket;
  compact?: boolean;
  demandOnly?: boolean;
}) {
  const tokens = bucket.prompt_tokens + bucket.completion_tokens;

  return (
    <div className="border-b border-border-dim pb-3 last:border-b-0 last:pb-0">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex min-w-0 items-center gap-2">
            <p className="truncate text-sm font-semibold text-text-primary">
              {formatPlace(bucket)}
            </p>
            {demandOnly && (
              <span className="shrink-0 rounded-full border border-accent-amber/30 bg-accent-amber-dim px-1.5 py-0.5 text-[9px] font-mono uppercase tracking-wider text-accent-amber">
                no local provider
              </span>
            )}
          </div>
          {!compact && (
            <p className="text-xs font-mono text-text-tertiary truncate mt-0.5">
              {formatNumber(tokens)} tokens
            </p>
          )}
        </div>
        <div className="text-right shrink-0">
          <p className="text-sm font-mono font-bold text-text-primary">
            {formatNumber(bucket.requests)}
          </p>
          <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
            req
          </p>
        </div>
      </div>
      <div className="mt-2 flex items-center gap-2 text-[11px] font-mono text-text-tertiary">
        <span>{formatNumber(bucket.prompt_tokens)} in</span>
        <span className="text-border-subtle">/</span>
        <span>{formatNumber(bucket.completion_tokens)} out</span>
        <span className="text-border-subtle">/</span>
        <span>{demandOnly ? "routed remote" : `${formatNumber(bucket.providers)} nodes`}</span>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Activity bar chart
// ---------------------------------------------------------------------------
function ActivityChart({
  data,
  label,
  color,
  getValue,
}: {
  data: TimeSeriesBucket[];
  label: string;
  color: string;
  getValue: (d: TimeSeriesBucket) => number;
}) {
  const chartData = normalizeTimeSeries(data);
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const values = chartData.map(getValue);
  const max = Math.max(...values, 1);
  const hasData = values.some((v) => v > 0);
  const width = 420;
  const height = 160;
  const padX = 14;
  const padY = 14;
  const chartWidth = width - padX * 2;
  const chartHeight = height - padY * 2;
  const points = values.map((v, i) => {
    const x = chartData.length <= 1 ? padX : padX + (i / (chartData.length - 1)) * chartWidth;
    const y = padY + chartHeight - (v / max) * chartHeight;
    return { x, y, value: v, source: chartData[i] };
  });
  const linePath = points
    .map((p, i) => `${i === 0 ? "M" : "L"}${p.x.toFixed(1)} ${p.y.toFixed(1)}`)
    .join(" ");
  const areaPath =
    points.length > 0
      ? `${linePath} L${points[points.length - 1].x.toFixed(1)} ${height - padY} L${points[0].x.toFixed(1)} ${height - padY} Z`
      : "";
  const total = values.reduce((sum, v) => sum + v, 0);
  const peak = Math.max(...values, 0);
  const hovered = hoverIndex === null ? null : points[hoverIndex];
  const hoverPct = hovered ? (hovered.x / width) * 100 : 0;

  function updateHover(clientX: number, rect: DOMRect) {
    if (points.length === 0) return;
    const relative = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    setHoverIndex(Math.round(relative * (points.length - 1)));
  }

  return (
    <div className="bg-bg-white rounded-xl p-5 space-y-4 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
            {label}
          </h3>
          <p className="text-xs text-text-tertiary mt-1">
            {formatNumber(total)} total / {formatNumber(peak)} peak
          </p>
        </div>
        <span className="text-xs font-mono text-text-tertiary">
          Last {chartData.length} min
        </span>
      </div>
      <div
        data-chart="requests-per-minute"
        className="relative h-40 overflow-hidden rounded-lg border border-border-dim bg-bg-secondary"
        aria-label={`${label} chart`}
        onMouseMove={(event) => updateHover(event.clientX, event.currentTarget.getBoundingClientRect())}
        onClick={(event) => updateHover(event.clientX, event.currentTarget.getBoundingClientRect())}
        onMouseLeave={() => setHoverIndex(null)}
        onFocus={() => setHoverIndex((current) => current ?? points.length - 1)}
        onBlur={() => setHoverIndex(null)}
        tabIndex={hasData ? 0 : -1}
      >
        {!hasData ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2">
            <p className="text-xs font-mono text-text-tertiary">
              Activity will appear here
            </p>
          </div>
        ) : (
          <svg className="absolute inset-0 h-full w-full" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none">
            <defs>
              <linearGradient id={`area-${label.replace(/\W/g, "-")}`} x1="0" x2="0" y1="0" y2="1">
                <stop offset="0%" stopColor={color} stopOpacity="0.26" />
                <stop offset="100%" stopColor={color} stopOpacity="0.02" />
              </linearGradient>
            </defs>
            {[0.25, 0.5, 0.75].map((t) => (
              <line
                key={t}
                x1={padX}
                x2={width - padX}
                y1={padY + chartHeight * t}
                y2={padY + chartHeight * t}
                stroke="var(--border-subtle)"
                strokeWidth="1"
                vectorEffect="non-scaling-stroke"
                opacity="0.55"
              />
            ))}
            <path d={areaPath} fill={`url(#area-${label.replace(/\W/g, "-")})`} />
            <path
              d={linePath}
              fill="none"
              stroke={color}
              strokeWidth="2.5"
              vectorEffect="non-scaling-stroke"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
            {points.filter((_, i) => i === 0 || i === points.length - 1 || points[i].value === peak).map((p, i) => (
              <circle key={`${p.x}-${i}`} cx={p.x} cy={p.y} r="3.5" fill={color} stroke="var(--bg-secondary)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
            ))}
            {hovered && (
              <g>
                <line
                  x1={hovered.x}
                  x2={hovered.x}
                  y1={padY}
                  y2={height - padY}
                  stroke="var(--text-tertiary)"
                  strokeOpacity="0.35"
                  strokeWidth="1"
                  vectorEffect="non-scaling-stroke"
                />
                <circle
                  cx={hovered.x}
                  cy={hovered.y}
                  r="4.5"
                  fill={color}
                  stroke="var(--bg-primary)"
                  strokeWidth="2"
                  vectorEffect="non-scaling-stroke"
                />
              </g>
            )}
          </svg>
        )}
        {hovered && (
          <div
            className="pointer-events-none absolute top-3 z-10 min-w-[118px] rounded-lg border border-border-dim bg-bg-primary/95 px-3 py-2 text-xs shadow-lg backdrop-blur"
            style={{
              left: `${hoverPct}%`,
              transform: hoverPct > 72 ? "translateX(-100%)" : hoverPct < 28 ? "translateX(0)" : "translateX(-50%)",
            }}
          >
            <p className="font-mono text-text-tertiary">{formatChartMinute(hovered.source.timestamp)}</p>
            <p className="mt-1 font-mono font-semibold text-text-primary">
              {formatNumber(hovered.value)} requests
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Stacked token chart
// ---------------------------------------------------------------------------
function TokenChart({ data }: { data: TimeSeriesBucket[] }) {
  const chartData = normalizeTimeSeries(data);
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const hasData = chartData.some(
    (d) => d.prompt_tokens + d.completion_tokens > 0
  );
  const maxTokens = Math.max(
    ...chartData.map((d) => d.prompt_tokens + d.completion_tokens),
    1
  );
  const width = 420;
  const height = 160;
  const padX = 12;
  const padY = 14;
  const chartHeight = height - padY * 2;
  const totalInput = chartData.reduce((sum, d) => sum + d.prompt_tokens, 0);
  const totalOutput = chartData.reduce((sum, d) => sum + d.completion_tokens, 0);
  const barGap = 3;
  const barWidth = chartData.length > 0
    ? Math.max(3, (width - padX * 2 - barGap * (chartData.length - 1)) / chartData.length)
    : 0;
  const hovered = hoverIndex === null ? null : chartData[hoverIndex];
  const hoverX = hoverIndex === null ? 0 : padX + hoverIndex * (barWidth + barGap) + barWidth / 2;
  const hoverPct = (hoverX / width) * 100;

  function updateHover(clientX: number, rect: DOMRect) {
    if (chartData.length === 0) return;
    const relative = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    setHoverIndex(Math.round(relative * (chartData.length - 1)));
  }

  return (
    <div className="bg-bg-white rounded-xl p-5 space-y-4 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
            Tokens / Minute
          </h3>
          <p className="text-xs text-text-tertiary mt-1">
            {formatNumber(totalInput + totalOutput)} tokens / {chartData.length} min
          </p>
        </div>
        <div className="flex items-center gap-3">
          <span className="flex items-center gap-1 text-xs font-mono text-text-tertiary">
            <span className="w-2 h-2 rounded-sm" style={{ background: "var(--accent-brand)" }} />
            Input
          </span>
          <span className="flex items-center gap-1 text-xs font-mono text-text-tertiary">
            <span className="w-2 h-2 rounded-sm" style={{ background: "var(--accent-green)" }} />
            Output
          </span>
        </div>
      </div>
      <div
        data-chart="tokens-per-minute"
        className="relative h-40 overflow-hidden rounded-lg border border-border-dim bg-bg-secondary"
        aria-label="Tokens per minute chart"
        onMouseMove={(event) => updateHover(event.clientX, event.currentTarget.getBoundingClientRect())}
        onClick={(event) => updateHover(event.clientX, event.currentTarget.getBoundingClientRect())}
        onMouseLeave={() => setHoverIndex(null)}
        onFocus={() => setHoverIndex((current) => current ?? chartData.length - 1)}
        onBlur={() => setHoverIndex(null)}
        tabIndex={hasData ? 0 : -1}
      >
        {!hasData ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2">
            <p className="text-xs font-mono text-text-tertiary">
              Token flow will appear here
            </p>
          </div>
        ) : (
          <svg className="absolute inset-0 h-full w-full" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none">
            {[0.25, 0.5, 0.75].map((t) => (
              <line
                key={t}
                x1={padX}
                x2={width - padX}
                y1={padY + chartHeight * t}
                y2={padY + chartHeight * t}
                stroke="var(--border-subtle)"
                strokeWidth="1"
                vectorEffect="non-scaling-stroke"
                opacity="0.55"
              />
            ))}
            {chartData.map((d, i) => {
              const total = d.prompt_tokens + d.completion_tokens;
              const fullHeight = Math.max(3, (total / maxTokens) * chartHeight);
              const outputHeight = total > 0 ? (d.completion_tokens / total) * fullHeight : 0;
              const inputHeight = fullHeight - outputHeight;
              const x = padX + i * (barWidth + barGap);
              const y = padY + chartHeight - fullHeight;
              const active = i === hoverIndex;
              return (
                <g key={`${d.timestamp}-${i}`}>
                  <rect
                    x={x}
                    y={y}
                    width={barWidth}
                    height={inputHeight}
                    rx="2"
                    fill="var(--accent-brand)"
                    opacity={active ? "0.96" : "0.74"}
                  />
                  <rect
                    x={x}
                    y={y + inputHeight}
                    width={barWidth}
                    height={outputHeight}
                    rx="2"
                    fill="var(--accent-green)"
                    opacity={active ? "0.96" : "0.74"}
                  />
                </g>
              );
            })}
            {hovered && (
              <line
                x1={hoverX}
                x2={hoverX}
                y1={padY}
                y2={height - padY}
                stroke="var(--text-tertiary)"
                strokeOpacity="0.32"
                strokeWidth="1"
                vectorEffect="non-scaling-stroke"
              />
            )}
          </svg>
        )}
        {hovered && (
          <div
            className="pointer-events-none absolute top-3 z-10 min-w-[150px] rounded-lg border border-border-dim bg-bg-primary/95 px-3 py-2 text-xs shadow-lg backdrop-blur"
            style={{
              left: `${hoverPct}%`,
              transform: hoverPct > 72 ? "translateX(-100%)" : hoverPct < 28 ? "translateX(0)" : "translateX(-50%)",
            }}
          >
            <p className="font-mono text-text-tertiary">{formatChartMinute(hovered.timestamp)}</p>
            <p className="mt-1 font-mono font-semibold text-text-primary">
              {formatNumber(hovered.prompt_tokens + hovered.completion_tokens)} tokens
            </p>
            <p className="mt-1 font-mono text-text-tertiary">
              {formatNumber(hovered.prompt_tokens)} in / {formatNumber(hovered.completion_tokens)} out
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

function NodeMetric({
  label,
  value,
  icon,
}: {
  label: string;
  value: string;
  icon: ReactNode;
}) {
  return (
    <div className="rounded-lg border border-border-dim bg-bg-secondary px-3 py-2">
      <div className="flex items-center gap-1.5 text-text-tertiary">
        {icon}
        <p className="text-[10px] font-mono uppercase tracking-wider">{label}</p>
      </div>
      <p className="mt-1 text-sm font-mono font-semibold text-text-primary">{value}</p>
    </div>
  );
}

function VerifyStepLine({ step }: { step: VerificationStep }) {
  let icon = <Clock size={12} className="text-text-tertiary" />;
  if (step.status === "success") {
    icon = <CheckCircle2 size={12} className="text-accent-green" />;
  }
  if (step.status === "error") {
    icon = <XCircle size={12} className="text-accent-red" />;
  }
  if (step.status === "running") {
    icon = <Loader2 size={12} className="animate-spin text-accent-brand" />;
  }

  return (
    <div className="flex gap-2 py-1.5">
      <div className="mt-0.5 shrink-0">{icon}</div>
      <div className="min-w-0">
        <p className="text-xs text-text-secondary">{step.label}</p>
        {step.detail && (
          <p className="mt-0.5 break-words text-[11px] font-mono text-text-tertiary">
            {step.detail}
          </p>
        )}
      </div>
    </div>
  );
}

function NodeRow({
  provider,
  selected,
  maxCapacity,
  onSelect,
}: {
  provider: ProviderStats;
  selected: boolean;
  maxCapacity: number;
  onSelect: () => void;
}) {
  const capacityPct = Math.max(5, (providerCapacityScore(provider) / maxCapacity) * 100);
  const activeModel = provider.current_model || provider.models?.[0] || "";

  return (
    <button
      type="button"
      onClick={onSelect}
      className={`w-full rounded-xl border px-4 py-3 text-left transition-all ${
        selected
          ? "border-accent-brand/35 bg-accent-brand/5 shadow-sm"
          : "border-border-dim bg-bg-secondary hover:border-border-subtle hover:bg-bg-hover"
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-start gap-3">
          <StatusDot status={provider.status} />
          <div className="min-w-0">
            <div className="flex min-w-0 items-center gap-2">
              <p className="truncate text-sm font-semibold text-text-primary">
                {provider.chip}
              </p>
              {isProviderRoutable(provider) && (
                <span className="rounded-full bg-accent-green/10 px-1.5 py-0.5 text-[10px] font-medium text-accent-green">
                  Routable
                </span>
              )}
            </div>
            <p className="mt-0.5 truncate text-xs font-mono text-text-tertiary">
              {provider.machine_model || "Apple Silicon"} · {compactId(provider.id)}
            </p>
          </div>
        </div>
        <TrustBadge level={provider.trust_level} />
      </div>

      <div className="mt-3 grid grid-cols-4 gap-2 text-xs font-mono">
        <div>
          <p className="text-text-tertiary">RAM</p>
          <p className="text-text-primary">{provider.memory_gb} GB</p>
        </div>
        <div>
          <p className="text-text-tertiary">GPU</p>
          <p className="text-text-primary">{provider.gpu_cores}</p>
        </div>
        <div>
          <p className="text-text-tertiary">Req</p>
          <p className="text-text-primary">{formatNumber(provider.requests_served)}</p>
        </div>
        <div>
          <p className="text-text-tertiary">Tok</p>
          <p className="text-text-primary">{formatNumber(provider.tokens_generated)}</p>
        </div>
      </div>

      <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-bg-elevated">
        <div
          className="h-full rounded-full bg-accent-brand"
          style={{
            width: `${Math.min(100, capacityPct)}%`,
            opacity: selected ? 0.92 : 0.58,
          }}
        />
      </div>

      {activeModel && (
        <p className="mt-2 truncate text-[11px] font-mono text-text-tertiary">
          {shortModelName(activeModel)}
        </p>
      )}
    </button>
  );
}

function NodeDetail({
  provider,
  verifying,
  verifySteps,
  verifyResult,
  attestation,
  onVerify,
}: {
  provider: ProviderStats | null;
  verifying: boolean;
  verifySteps: VerificationStep[];
  verifyResult: CertVerificationResult | null;
  attestation: ProviderAttestation | null;
  onVerify: (provider: ProviderStats) => void;
}) {
  if (!provider) {
    return (
      <div className="rounded-xl border border-border-dim bg-bg-secondary p-5 text-sm text-text-tertiary">
        Select a node to inspect its capacity and verification state.
      </div>
    );
  }

  const certCount = attestation?.mda_cert_chain_b64?.length ?? 0;
  const verifiedSerial = maskSerial(
    verifyResult?.deviceInfo?.serial || attestation?.mda_serial || attestation?.serial_number
  );
  const modelList = provider.models ?? [];
  let verificationState = "Certificate not checked";
  let verificationColor = "text-text-tertiary";
  if (verifyResult?.success) {
    verificationState = "Apple certificate verified";
    verificationColor = "text-accent-green";
  }
  if (verifyResult && !verifyResult.success) {
    verificationState = "Certificate check failed";
    verificationColor = "text-accent-red";
  }

  return (
    <div className="rounded-xl border border-border-dim bg-bg-secondary p-5 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Server size={16} className="text-accent-brand" />
            <h3 className="truncate text-sm font-semibold text-text-primary">
              {provider.chip}
            </h3>
          </div>
          <p className="mt-1 truncate text-xs font-mono text-text-tertiary">
            {provider.machine_model} · {provider.id}
          </p>
        </div>
        <StatusDot status={provider.status} />
      </div>

      <div className="mt-4 grid grid-cols-2 gap-2">
        <NodeMetric label="Memory" value={`${provider.memory_gb} GB`} icon={<HardDrive size={12} />} />
        <NodeMetric label="GPU" value={`${provider.gpu_cores}-core`} icon={<Cpu size={12} />} />
        <NodeMetric label="CPU" value={`${provider.cpu_cores.performance}P + ${provider.cpu_cores.efficiency}E`} icon={<Activity size={12} />} />
        <NodeMetric label="Bandwidth" value={`${provider.memory_bandwidth_gbs} GB/s`} icon={<Zap size={12} />} />
      </div>

      <div className="mt-4 rounded-lg border border-border-dim bg-bg-primary p-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className="text-xs font-semibold text-text-primary">Certificate verification</p>
            <p className={`mt-0.5 text-[11px] font-mono ${verificationColor}`}>
              {verificationState}
            </p>
          </div>
          <button
            type="button"
            onClick={() => onVerify(provider)}
            disabled={verifying}
            className="inline-flex items-center gap-1.5 rounded-lg border border-border-subtle px-2.5 py-1.5 text-xs font-medium text-text-secondary transition-colors hover:bg-bg-hover disabled:cursor-not-allowed disabled:opacity-60"
          >
            {verifying ? <Loader2 size={12} className="animate-spin" /> : <ShieldCheck size={12} />}
            Verify
          </button>
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2 text-[11px] font-mono">
          <div className="rounded-md bg-bg-secondary px-2 py-1.5">
            <p className="text-text-tertiary">Trust</p>
            <p className="text-text-primary">{verificationLabel(provider)}</p>
          </div>
          <div className="rounded-md bg-bg-secondary px-2 py-1.5">
            <p className="text-text-tertiary">Challenge</p>
            <p className="text-text-primary">{relativeChallengeLabel(provider.last_challenge_verified)}</p>
          </div>
          <div className="rounded-md bg-bg-secondary px-2 py-1.5">
            <p className="text-text-tertiary">Certificates</p>
            <p className="text-text-primary">{certCount > 0 ? certCount : provider.certificate_available ? "available" : "none"}</p>
          </div>
          <div className="rounded-md bg-bg-secondary px-2 py-1.5">
            <p className="text-text-tertiary">Serial</p>
            <p className="text-text-primary">{verifiedSerial || "hidden"}</p>
          </div>
        </div>

        {(verifySteps.length > 0 || verifyResult?.error) && (
          <div className="mt-3 border-t border-border-dim pt-2">
            {verifySteps.map((step) => (
              <VerifyStepLine key={step.label} step={step} />
            ))}
            {verifyResult?.error && (
              <p className="mt-2 rounded-md bg-accent-red/5 px-2 py-1.5 text-[11px] text-accent-red">
                {verifyResult.error}
              </p>
            )}
          </div>
        )}
      </div>

      <div className="mt-4">
        <p className="text-xs font-mono uppercase tracking-wider text-text-tertiary">
          Models
        </p>
        <div className="mt-2 flex flex-wrap gap-1.5">
          {modelList.length === 0 ? (
            <span className="text-xs text-text-tertiary">No model list reported.</span>
          ) : (
            modelList.map((model) => (
              <span
                key={model}
                className={`rounded-md px-2 py-1 text-[11px] font-mono ${
                  model === provider.current_model
                    ? "bg-accent-brand/10 text-accent-brand"
                    : "bg-bg-primary text-text-tertiary"
                }`}
              >
                {shortModelName(model)}
              </span>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

function NetworkNodes({ providers }: { providers: ProviderStats[] }) {
  const [selectedProviderId, setSelectedProviderId] = useState<string>("");
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<NodeStatusFilter>("all");
  const [trustFilter, setTrustFilter] = useState<NodeTrustFilter>("all");
  const [modelFilter, setModelFilter] = useState("all");
  const [sortKey, setSortKey] = useState<NodeSortKey>("capacity");
  const [verifyingId, setVerifyingId] = useState<string | null>(null);
  const [verifySteps, setVerifySteps] = useState<VerificationStep[]>([]);
  const [verifyResult, setVerifyResult] = useState<CertVerificationResult | null>(null);
  const [attestation, setAttestation] = useState<ProviderAttestation | null>(null);
  const statusOptions: Array<{ value: NodeStatusFilter; label: string }> = [
    { value: "all", label: "All" },
    { value: "routable", label: "Routable" },
    { value: "serving", label: "Serving" },
    { value: "online", label: "Online" },
    { value: "attention", label: "Needs attention" },
  ];
  const trustOptions: Array<{ value: NodeTrustFilter; label: string }> = [
    { value: "all", label: "All trust" },
    { value: "hardware", label: "Hardware" },
    { value: "none", label: "Basic" },
  ];

  const modelOptions = useMemo(() => {
    return Array.from(new Set(providers.flatMap((provider) => provider.models ?? [])))
      .sort((a, b) => shortModelName(a).localeCompare(shortModelName(b)));
  }, [providers]);

  const filteredProviders = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return providers
      .filter((provider) => {
        const modelNames = provider.models ?? [];
        const haystack = [
          provider.id,
          provider.chip,
          provider.machine_model,
          provider.status,
          provider.trust_level,
          provider.current_model,
          ...modelNames,
        ]
          .filter(Boolean)
          .join(" ")
          .toLowerCase();
        const matchesQuery = normalizedQuery === "" || haystack.includes(normalizedQuery);
        const matchesStatus =
          statusFilter === "all" ||
          (statusFilter === "routable" && isProviderRoutable(provider)) ||
          (statusFilter === "attention" && !isProviderRoutable(provider)) ||
          provider.status === statusFilter;
        const matchesTrust = trustFilter === "all" || provider.trust_level === trustFilter;
        const matchesModel = modelFilter === "all" || modelNames.includes(modelFilter);
        return matchesQuery && matchesStatus && matchesTrust && matchesModel;
      })
      .sort((a, b) => compareProviders(a, b, sortKey));
  }, [modelFilter, providers, query, sortKey, statusFilter, trustFilter]);

  const selectedProvider =
    filteredProviders.find((provider) => provider.id === selectedProviderId) ??
    filteredProviders[0] ??
    null;
  const maxCapacity = Math.max(
    ...providers.map((provider) => providerCapacityScore(provider)),
    1
  );
  const servingCount = providers.filter((provider) => provider.status === "serving").length;
  const routableCount = providers.filter(isProviderRoutable).length;

  useEffect(() => {
    if (selectedProvider && selectedProvider.id !== selectedProviderId) {
      setSelectedProviderId(selectedProvider.id);
    }
  }, [selectedProvider, selectedProviderId]);

  useEffect(() => {
    setVerifySteps([]);
    setVerifyResult(null);
    setAttestation(null);
  }, [selectedProviderId]);

  async function handleVerify(provider: ProviderStats) {
    setVerifyingId(provider.id);
    setVerifySteps([]);
    setVerifyResult(null);
    setAttestation(null);

    try {
      const response = await fetch("/api/attestation");
      if (!response.ok) {
        throw new Error(`Attestation API returned HTTP ${response.status}`);
      }
      const data = await response.json();
      const attestedProviders: ProviderAttestation[] = data.providers ?? [];
      const matched =
        attestedProviders.find((entry) => entry.provider_id === provider.id) ??
        attestedProviders.find((entry) => entry.provider_id?.startsWith(provider.id)) ??
        null;

      if (!matched) {
        setVerifyResult({
          success: false,
          steps: [],
          error: "Node was not present in the public attestation feed.",
        });
        return;
      }

      setAttestation(matched);
      const certs = matched.mda_cert_chain_b64 ?? [];
      if (certs.length < 2) {
        setVerifyResult({
          success: false,
          steps: [
            {
              status: "error",
              label: "Insufficient certificate chain",
              detail: `Got ${certs.length}, need at least 2 certificates.`,
            },
          ],
          error: "This node has no Apple MDA certificate chain available yet.",
        });
        return;
      }

      const { verifyCertificateChain } = await import("@/lib/cert-verify");
      const result = await verifyCertificateChain(certs, (steps) => {
        setVerifySteps(steps);
      });
      setVerifyResult(result);
    } catch (error) {
      setVerifyResult({
        success: false,
        steps: [],
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setVerifyingId(null);
    }
  }

  return (
    <section className="rounded-xl border border-border-dim bg-bg-white p-5 shadow-sm">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <div className="flex items-center gap-2">
            <Server size={16} className="text-accent-brand" />
            <h2 className="text-sm font-semibold text-text-primary">Provider Dashboard</h2>
          </div>
          <p className="mt-1 text-xs text-text-tertiary">
            Routability, node health, model coverage, and certificate verification
          </p>
        </div>
        <div className="grid grid-cols-3 gap-3 text-right">
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">{providers.length}</p>
            <p className="text-xs font-medium text-text-tertiary">Nodes</p>
          </div>
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">{routableCount}</p>
            <p className="text-xs font-medium text-text-tertiary">Routable</p>
          </div>
          <div>
            <p className="text-lg font-mono font-bold text-text-primary">{servingCount}</p>
            <p className="text-xs font-medium text-text-tertiary">Serving</p>
          </div>
        </div>
      </div>

      <div className="mt-5 grid grid-cols-1 gap-3 lg:grid-cols-[minmax(260px,1fr)_220px_180px]">
        <label className="relative block">
          <Search size={14} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary" />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search node, chip, model, id"
            className="h-10 w-full rounded-lg border border-border-dim bg-bg-secondary pl-9 pr-3 text-sm text-text-primary outline-none transition-colors placeholder:text-text-tertiary focus:border-accent-brand/40"
          />
        </label>

        <select
          value={modelFilter}
          onChange={(event) => setModelFilter(event.target.value)}
          className="h-10 rounded-lg border border-border-dim bg-bg-secondary px-3 text-sm font-medium text-text-primary outline-none focus:border-accent-brand/40"
        >
          <option value="all">All models</option>
          {modelOptions.map((model) => (
            <option key={model} value={model}>
              {shortModelName(model)}
            </option>
          ))}
        </select>

        <select
          value={sortKey}
          onChange={(event) => setSortKey(event.target.value as NodeSortKey)}
          className="h-10 rounded-lg border border-border-dim bg-bg-secondary px-3 text-sm font-medium text-text-primary outline-none focus:border-accent-brand/40"
        >
          <option value="capacity">Sort by capacity</option>
          <option value="requests">Sort by requests</option>
          <option value="tokens">Sort by tokens</option>
          <option value="chip">Sort by chip</option>
        </select>
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <span className="inline-flex items-center gap-1.5 text-xs font-medium text-text-tertiary">
          <SlidersHorizontal size={13} />
          Status
        </span>
        {statusOptions.map((option) => (
          <button
            key={option.value}
            type="button"
            onClick={() => setStatusFilter(option.value)}
            className={`rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors ${
              statusFilter === option.value
                ? "border-accent-brand/35 bg-accent-brand/10 text-accent-brand"
                : "border-border-dim bg-bg-secondary text-text-secondary hover:border-border-subtle hover:bg-bg-hover"
            }`}
          >
            {option.label}
          </button>
        ))}
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-text-tertiary">Trust</span>
        {trustOptions.map((option) => (
          <button
            key={option.value}
            type="button"
            onClick={() => setTrustFilter(option.value)}
            className={`rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors ${
              trustFilter === option.value
                ? "border-accent-green/35 bg-accent-green/10 text-accent-green"
                : "border-border-dim bg-bg-secondary text-text-secondary hover:border-border-subtle hover:bg-bg-hover"
            }`}
          >
            {option.label}
          </button>
        ))}
      </div>

      <div className="mt-5">
        <div className="space-y-2">
          {filteredProviders.length === 0 ? (
            <div className="rounded-xl border border-border-dim bg-bg-secondary p-8 text-center text-sm text-text-tertiary">
              No nodes match the current filters.
            </div>
          ) : (
            filteredProviders.map((provider) => (
              <div key={provider.id} className="space-y-2">
                <NodeRow
                  provider={provider}
                  selected={provider.id === selectedProvider?.id}
                  maxCapacity={maxCapacity}
                  onSelect={() => setSelectedProviderId(provider.id)}
                />
                {provider.id === selectedProvider?.id && (
                  <div className="pl-0 sm:pl-8">
                    <NodeDetail
                      provider={provider}
                      verifying={verifyingId === provider.id}
                      verifySteps={verifySteps}
                      verifyResult={verifyResult}
                      attestation={attestation}
                      onVerify={handleVerify}
                    />
                  </div>
                )}
              </div>
            ))
          )}
        </div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------
export default function StatsPage() {
  const [stats, setStats] = useState<PlatformStats | null>(null);
  const [catalogData, setCatalogData] = useState<CatalogDataSummary | null>(null);
  const [capacityModels, setCapacityModels] = useState<CapacityModelSummary[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchStats = async () => {
    try {
      const query = typeof window === "undefined" ? "" : window.location.search;
      const [res, catalog, capacity] = await Promise.all([
        fetch(`/api/stats${query}`),
        fetchModelCatalog(),
        fetchModelCapacity(),
      ]);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setStats(data);
      if (catalog) {
        setCatalogData(catalog);
      }
      if (capacity) {
        setCapacityModels(capacity);
      }
      setError(null);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to fetch stats");
    } finally {
      setLoading(false);
    }
  };

  // Poll only while the tab is visible; pause in the background (perf F6).
  // Cadence raised 10s -> 15s to cut active request volume.
  useVisiblePolling(fetchStats, 15_000);

  // Memoize the per-poll aggregation so it doesn't recompute on unrelated
  // re-renders (perf F10): buildModelInventory iterates providers x aliases and
  // activeNetworkPowerWatts iterates providers. Declared above the early returns
  // to keep hook order stable.
  const visibleModelCount = useMemo(
    () => (stats ? buildModelInventory(stats, catalogData?.aliases ?? []).length : 0),
    [stats, catalogData],
  );
  const networkPowerWatts = useMemo(
    () => (stats ? activeNetworkPowerWatts(stats) : 0),
    [stats],
  );

  if (loading) {
    return (
      <div className="flex flex-col h-full">
        <TopBar title="Network Stats" />
        <div className="flex-1 flex items-center justify-center">
          <Loader2 size={24} className="animate-spin text-text-tertiary" />
        </div>
      </div>
    );
  }

  if (error || !stats) {
    return (
      <div className="flex flex-col h-full">
        <TopBar title="Network Stats" />
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center space-y-2">
            <p className="text-text-secondary text-sm">Failed to load platform stats</p>
            <p className="text-text-tertiary text-xs font-mono">{error}</p>
            <button onClick={fetchStats} className="mt-3 px-3 py-1.5 rounded-lg border border-border-subtle text-text-secondary text-xs hover:bg-bg-hover transition-colors">
              Retry
            </button>
          </div>
        </div>
      </div>
    );
  }

  const hardwareAttested = stats.providers.filter((p) => p.trust_level === "hardware").length;
  const nu = stats.network_utilization;
  const utilizationSub =
    nu && nu.bottleneck_model && (nu.bottleneck_utilization ?? 0) > (nu.utilization ?? 0)
      ? `peak ${formatPercent(nu.bottleneck_utilization ?? 0)} · ${nu.bottleneck_model}`
      : "in use";

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Network Stats" />
      {/* `relative` makes this the containing block for any absolutely-positioned
          descendants (e.g. the sr-only toggle checkbox in ActiveModelsSection).
          Without it, those abs elements escape this scroller's clip, anchor to
          <body>, and stretch the document — making the whole page scroll when the
          wheel is over the non-scrolling sidebar. */}
      <div className="flex-1 overflow-y-auto relative">
        <div className="max-w-5xl mx-auto px-3 sm:px-6 py-6 sm:py-8 space-y-6">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold text-text-primary tracking-tight">
              Network Statistics
            </h1>
            <p className="text-sm text-text-tertiary mt-1">
              Live metrics from the Darkbloom decentralized inference network
            </p>
          </div>
          <div className="flex items-center gap-3">
            <div className="flex items-center gap-1.5">
              <span className="relative flex h-2 w-2">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent-green opacity-40" />
                <span className="relative inline-flex rounded-full h-2 w-2 bg-accent-green" />
              </span>
              <span className="text-xs font-mono text-accent-green uppercase tracking-wider">Live</span>
            </div>
            <button onClick={fetchStats} className="p-2 rounded-lg border border-border-dim hover:border-border-subtle hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-all">
              <RefreshCw size={14} />
            </button>
          </div>
        </div>

        {/* Hero section -- big numbers */}
        <div className="bg-bg-white rounded-2xl p-8 shadow-sm">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-8">
            <HeroStat
              value={formatNumber(stats.total_tokens)}
              label="Tokens Served"
              sub={`${formatNumber(stats.total_prompt_tokens)} in / ${formatNumber(stats.total_completion_tokens)} out`}
            />
            <HeroStat
              value={formatNumber(stats.total_requests)}
              label="Requests"
            />
            <HeroStat
              value={stats.active_providers.toString()}
              label="Nodes Online"
              sub={hardwareAttested === stats.active_providers ? "all hardware-attested" : `${hardwareAttested} hardware-attested`}
            />
            <HeroStat
              value={`${Math.round(stats.total_bandwidth_gbs)}`}
              label="GB/s Bandwidth"
              sub="combined memory throughput"
            />
          </div>
        </div>

        {/* Hardware capacity grid (+ network power) */}
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-5 gap-3">
          {networkPowerWatts > 0 && (
            <MiniStat
              label="Network Power"
              value={formatPower(networkPowerWatts)}
              sub="under load"
            />
          )}
          {typeof stats.network_utilization?.utilization === "number" && (
            <MiniStat
              label="Network Utilization"
              value={formatPercent(stats.network_utilization.utilization)}
              sub={utilizationSub}
            />
          )}
          <MiniStat label="GPU Cores" value={stats.total_gpu_cores.toString()} sub="Apple Silicon" />
          <MiniStat label="CPU Cores" value={stats.total_cpu_cores.toString()} sub="P + E cores" />
          <MiniStat label="Unified RAM" value={`${stats.total_memory_gb} GB`} />
          <MiniStat
            label="Avg Tok/Req"
            value={stats.avg_tokens_per_request > 0 ? stats.avg_tokens_per_request.toFixed(0) : "--"}
          />
          <MiniStat
            label="Models"
            value={visibleModelCount.toString()}
            sub="serving now"
          />
        </div>

        {/* Charts */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <ActivityChart
            data={stats.time_series}
            label="Requests / Minute"
            color="var(--accent-brand)"
            getValue={(d) => d.requests}
          />
          <TokenChart data={stats.time_series} />
        </div>

        {/* Token distribution bar (only if there are tokens) */}
        {stats.total_tokens > 0 && (
          <div className="bg-bg-white rounded-xl p-5 space-y-3 shadow-sm">
            <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
              Token Distribution
            </h3>
            <div className="flex rounded-lg overflow-hidden h-7">
              <div
                className="flex items-center justify-center text-xs font-mono text-white font-medium transition-all duration-500"
                style={{
                  width: `${(stats.total_prompt_tokens / stats.total_tokens) * 100}%`,
                  minWidth: stats.total_prompt_tokens > 0 ? "70px" : "0",
                  background: "var(--accent-brand)",
                  opacity: 0.75,
                }}
              >
                {formatNumber(stats.total_prompt_tokens)} in ({((stats.total_prompt_tokens / stats.total_tokens) * 100).toFixed(0)}%)
              </div>
              <div
                className="flex items-center justify-center text-xs font-mono text-white font-medium transition-all duration-500"
                style={{
                  width: `${(stats.total_completion_tokens / stats.total_tokens) * 100}%`,
                  minWidth: stats.total_completion_tokens > 0 ? "70px" : "0",
                  background: "var(--accent-green)",
                  opacity: 0.75,
                }}
              >
                {formatNumber(stats.total_completion_tokens)} out ({((stats.total_completion_tokens / stats.total_tokens) * 100).toFixed(0)}%)
              </div>
            </div>
          </div>
        )}

        <ProviderGeography stats={stats} />
        <RequestGeography stats={stats} />

        {/* Models */}
        {stats.models.length > 0 && (
          <ActiveModelsSection
            stats={stats}
            catalogData={catalogData}
            capacityModels={capacityModels}
          />
        )}

        <NetworkNodes providers={stats.providers} />

        {/* Footer */}
        <div className="text-center pb-8">
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest">
            Auto-refreshes every 15 seconds
          </p>
        </div>
        </div>
      </div>
    </div>
  );
}
