"use client";

import Link from "next/link";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import {
  Activity,
  BarChart3,
  CheckCircle2,
  CircleDollarSign,
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
  Trophy,
  Users,
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
import {
  verifyCertificateChain,
  type CertVerificationResult,
  type VerificationStep,
} from "@/lib/cert-verify";
import { formatPower } from "@/lib/format-power";
import { activeNetworkPowerWatts } from "@/lib/network-power";

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
type StatsTab = "overview" | "leaderboard";
type LeaderboardMetric = "earnings" | "tokens" | "jobs";
type LeaderboardWindow = "24h" | "7d" | "30d" | "all";

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

interface LeaderboardEntry {
  rank: number;
  pseudonym: string;
  earnings_micro_usd: number;
  tokens: number;
  jobs: number;
}

interface LeaderboardResponse {
  metric: LeaderboardMetric;
  window: LeaderboardWindow;
  entries: LeaderboardEntry[];
  updated_at: string;
}

interface NetworkTotalsResponse {
  window: LeaderboardWindow;
  earnings_micro_usd: number;
  tokens: number;
  jobs: number;
  active_accounts: number;
  updated_at: string;
}

function formatNumber(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return n.toLocaleString();
}

function formatUSDFromMicro(value: number): string {
  const dollars = value / 1_000_000;
  if (dollars >= 1000) return `$${formatNumber(Math.round(dollars))}`;
  if (dollars >= 10) return `$${dollars.toFixed(0)}`;
  return `$${dollars.toFixed(2)}`;
}

function formatLeaderboardValue(entry: LeaderboardEntry, metric: LeaderboardMetric): string {
  if (metric === "earnings") return formatUSDFromMicro(entry.earnings_micro_usd);
  if (metric === "tokens") return formatNumber(entry.tokens);
  return formatNumber(entry.jobs);
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

async function fetchLeaderboard(
  metric: LeaderboardMetric,
  window: LeaderboardWindow,
): Promise<LeaderboardResponse> {
  const params = new URLSearchParams({ metric, window, limit: "50" });
  const res = await fetch(`/api/leaderboard?${params.toString()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Leaderboard HTTP ${res.status}`);
  return res.json();
}

async function fetchNetworkTotals(window: LeaderboardWindow): Promise<NetworkTotalsResponse> {
  const params = new URLSearchParams({ window });
  const res = await fetch(`/api/network/totals?${params.toString()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Network totals HTTP ${res.status}`);
  return res.json();
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
    <div className="rounded-xl border border-border-dim bg-bg-primary px-4 py-3 shadow-sm">
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
    <section className="rounded-xl border border-border-dim bg-bg-primary p-5 shadow-sm">
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

const WORLD_LAND_PATH = "M311.8 399.6 L318.1 403.3 L313.1 403.6 L305.7 403.3 L296.4 399.9 L298.8 399.2 L304.8 397.0 L310.4 397.5 Z M337.4 391.9 L335.0 395.0 L330.0 394.0 L337.4 391.9 Z M903.9 363.3 L910.2 363.4 L911.2 367.8 L908.0 371.2 L904.0 368.6 L902.1 363.1 Z M980.6 363.7 L984.0 364.9 L981.2 369.4 L978.6 371.8 L973.9 377.5 L967.8 379.5 L962.5 377.4 L969.3 372.0 L975.3 368.1 L978.0 363.8 Z M985.0 350.4 L988.4 352.2 L992.9 355.4 L995.2 357.2 L991.5 359.6 L990.3 362.8 L986.3 365.1 L985.8 360.9 L984.9 357.8 L984.1 352.0 L980.7 347.9 L982.1 347.2 Z M964.2 311.6 L959.6 310.2 L955.6 305.8 L959.6 307.8 L964.2 311.6 Z M0.0 296.0 L996.1 296.2 L0.0 294.6 L0.2 295.8 Z M639.0 287.7 L639.9 293.6 L638.0 293.6 L637.5 297.5 L634.9 306.9 L630.8 319.3 L624.5 320.4 L621.4 315.5 L620.6 309.3 L623.3 305.8 L622.3 300.9 L623.5 295.0 L627.4 293.9 L632.5 290.5 L634.1 288.3 L636.7 283.4 L639.0 287.7 Z M898.8 288.2 L902.5 290.5 L904.1 295.2 L906.0 299.3 L909.6 304.1 L913.1 307.3 L916.9 311.5 L919.2 315.2 L924.6 320.2 L925.3 325.7 L925.9 331.8 L924.7 337.9 L920.4 343.9 L917.6 349.1 L916.7 354.0 L909.4 356.2 L904.1 357.2 L901.3 355.8 L894.9 356.6 L888.9 353.9 L886.3 349.3 L883.9 345.5 L881.5 346.4 L882.8 341.4 L877.7 346.9 L873.9 342.3 L869.4 338.9 L859.8 337.8 L850.4 339.5 L844.5 343.0 L839.4 344.5 L833.0 344.4 L829.2 346.5 L824.0 347.3 L819.6 343.4 L821.3 341.4 L819.9 335.0 L818.4 330.0 L816.8 325.9 L816.0 323.7 L817.3 323.1 L815.6 318.6 L815.8 315.4 L817.1 310.4 L820.7 309.7 L825.5 307.3 L830.1 306.3 L832.8 305.5 L837.9 302.0 L839.8 297.9 L844.1 297.4 L845.2 295.4 L847.7 290.8 L850.3 289.9 L853.0 288.4 L858.3 291.3 L860.8 287.8 L862.8 284.8 L868.3 283.7 L867.7 280.9 L873.3 283.4 L877.4 283.2 L880.4 284.3 L877.7 287.0 L876.2 290.9 L880.7 294.1 L885.0 296.7 L889.5 299.2 L892.4 295.5 L893.2 290.4 L893.5 286.0 L894.2 283.0 L895.9 279.6 L897.5 283.1 L898.9 287.2 Z M845.7 278.2 L843.2 277.5 L847.5 274.0 L852.7 273.0 L849.8 275.3 Z M841.4 272.5 L841.0 274.0 L836.8 274.8 L833.1 274.5 L833.1 273.5 L835.3 272.9 L837.1 273.7 L838.9 273.5 L841.4 272.5 Z M801.7 268.8 L812.8 269.3 L821.4 273.3 L812.7 273.3 L804.0 271.5 L795.7 270.4 L794.6 266.4 L801.3 267.8 Z M933.0 268.9 L929.8 266.4 L929.9 264.8 L933.4 268.2 Z M922.2 265.2 L918.8 266.9 L913.6 266.7 L914.7 265.5 L917.1 263.9 L919.7 264.2 L922.6 261.5 L922.2 265.2 Z M862.4 258.6 L863.4 260.7 L861.1 259.6 L858.8 259.3 L857.2 259.5 L855.3 259.4 L855.9 257.9 L859.4 257.8 L862.4 258.6 Z M925.4 262.5 L923.3 260.5 L918.5 257.6 L921.7 258.3 L925.1 261.1 Z M872.6 253.2 L878.6 256.4 L886.6 255.7 L896.5 259.1 L905.1 263.5 L910.8 268.4 L911.3 272.3 L914.6 276.4 L918.9 278.6 L916.1 278.9 L908.7 276.4 L902.1 271.2 L898.4 275.0 L891.8 275.3 L885.8 273.3 L885.2 270.3 L877.7 262.6 L870.5 261.2 L868.8 259.2 L871.6 256.9 L866.2 254.5 L866.3 251.9 L872.6 253.2 Z M847.9 246.1 L840.9 248.8 L833.4 251.4 L842.6 251.7 L840.0 254.2 L839.6 259.8 L840.6 265.6 L838.2 263.5 L835.8 260.0 L834.4 261.4 L831.6 264.9 L830.8 259.7 L831.5 253.8 L835.8 246.4 L844.7 247.5 Z M857.5 246.9 L855.5 250.7 L854.7 250.7 L855.4 244.0 L857.5 246.9 Z M793.9 266.3 L785.0 261.7 L780.3 255.7 L774.9 247.1 L769.9 240.8 L764.7 234.8 L773.2 238.1 L779.6 244.2 L786.3 248.4 L788.9 252.9 L791.4 256.5 L794.0 262.0 Z M827.4 244.9 L826.3 249.7 L823.7 256.9 L819.1 261.4 L814.6 258.7 L808.5 258.5 L804.4 253.7 L803.0 246.3 L808.8 244.9 L813.9 241.4 L818.3 236.4 L824.2 230.8 L826.9 233.4 L830.9 236.1 L827.4 238.5 L827.4 244.9 Z M851.0 226.6 L850.5 232.6 L849.1 233.2 L844.3 230.9 L842.5 229.4 L838.7 230.0 L843.0 225.9 L846.6 225.1 L850.6 224.2 Z M725.6 232.8 L721.4 227.2 L725.8 226.2 L725.6 232.8 Z M844.4 221.4 L841.7 224.9 L841.2 221.5 L842.6 221.5 Z M829.2 224.1 L825.5 226.8 L826.8 224.8 L828.8 223.1 L830.5 221.2 L832.0 218.4 L832.5 220.7 L830.6 222.2 L829.2 224.1 Z M848.6 216.2 L847.3 219.5 L846.6 219.9 L846.9 218.3 L847.8 215.2 Z M837.0 198.6 L839.8 199.4 L839.6 204.8 L838.1 210.2 L844.3 211.7 L844.7 215.2 L840.8 213.4 L835.1 211.5 L835.3 209.0 L833.1 207.2 L834.4 201.1 Z M298.4 194.8 L303.3 194.8 L306.2 196.4 L308.9 197.3 L307.9 198.8 L305.2 199.3 L302.8 199.2 L300.8 199.9 L296.0 199.4 L293.4 198.2 L299.1 198.1 L296.1 195.4 Z M806.5 198.1 L801.7 196.2 L807.7 194.2 L806.5 198.1 Z M278.7 186.8 L283.4 188.1 L288.4 191.1 L291.9 192.5 L291.8 194.7 L284.0 194.8 L283.0 192.4 L279.8 190.1 L272.7 188.4 L270.1 187.0 L266.5 189.1 L265.4 188.3 L268.7 186.2 L273.9 185.8 Z M836.6 186.7 L835.4 189.0 L833.9 186.6 L833.6 184.6 L835.3 181.8 L837.5 179.7 L838.8 180.6 L838.3 182.2 L836.6 186.7 Z M874.0 155.1 L871.6 156.9 L867.7 158.4 L870.8 155.7 Z M596.0 150.9 L594.5 152.8 L589.6 152.5 L591.5 151.7 Z M543.1 143.8 L541.9 148.3 L534.5 145.5 L541.0 144.0 Z M525.6 135.5 L525.6 141.0 L523.3 137.8 L525.6 135.5 Z M891.6 146.8 L889.6 152.4 L877.2 157.0 L870.4 154.5 L866.7 157.9 L861.7 162.7 L859.5 157.5 L866.3 153.5 L876.9 151.3 L885.7 144.9 L888.6 137.3 L894.2 138.9 L891.6 146.8 Z M899.7 127.3 L904.3 129.8 L893.4 131.4 L888.4 131.8 L893.5 125.6 L899.7 127.3 Z M323.2 120.7 L325.2 121.1 L327.7 121.0 L326.4 122.1 L325.4 122.3 L321.8 121.1 L321.1 120.2 L322.2 119.3 L323.2 120.7 Z M328.3 113.6 L327.0 113.6 L323.4 112.8 L320.8 111.5 L321.7 111.2 L325.4 111.9 L328.2 113.1 L328.3 113.6 Z M156.9 115.3 L150.1 113.4 L144.3 111.1 L146.4 109.6 L151.6 111.3 L156.9 115.3 Z M344.1 109.2 L345.9 111.3 L348.7 112.3 L352.5 114.8 L352.6 120.4 L350.1 117.7 L344.5 119.7 L340.8 117.9 L336.7 116.0 L340.7 109.1 L346.1 106.7 Z M131.4 99.9 L135.6 105.1 L131.8 102.5 L130.1 99.5 Z M899.0 109.0 L896.0 117.1 L896.5 120.2 L894.5 117.3 L894.9 108.5 L896.1 100.7 L897.0 100.8 L899.0 109.0 Z M481.1 104.8 L474.5 103.2 L479.0 96.9 L482.8 100.4 Z M535.2 95.5 L533.6 97.8 L530.7 96.2 L530.3 95.1 L534.4 94.1 L535.2 95.5 Z M75.0 91.3 L72.2 92.4 L70.8 91.7 L70.4 90.4 L72.9 89.4 L74.4 89.0 L76.2 89.2 L77.4 90.0 L75.0 91.3 Z M491.7 87.1 L494.6 89.8 L494.2 94.7 L500.5 101.9 L504.3 105.3 L501.5 109.0 L491.8 109.2 L485.4 111.2 L490.5 107.2 L488.3 104.7 L491.4 101.7 L486.5 97.8 L486.0 95.0 L482.9 92.3 L488.3 87.4 Z M23.0 72.8 L28.7 73.8 L29.1 75.1 L23.5 74.1 Z M263.4 67.6 L267.0 69.1 L273.5 72.3 L275.0 73.9 L266.4 73.4 L257.7 73.5 L261.4 67.4 Z M459.7 65.4 L458.6 71.2 L444.5 73.2 L433.5 69.7 L432.4 67.7 L442.8 67.4 L455.1 65.2 Z M289.3 63.5 L286.1 63.6 L285.5 62.3 L286.6 60.7 L289.2 60.3 L291.4 61.1 L291.4 62.3 L291.1 62.7 L289.3 63.5 Z M0.0 58.4 L13.9 65.0 L22.6 64.1 L20.8 68.2 L17.0 71.4 L10.5 68.5 L3.1 67.4 L1.6 68.3 L1000.0 69.5 L995.3 72.0 L998.6 76.2 L984.9 78.4 L974.2 82.4 L961.9 83.9 L954.3 83.7 L950.1 89.3 L950.4 94.1 L945.5 99.0 L939.5 105.7 L933.3 102.3 L935.4 90.7 L944.9 85.2 L956.9 76.2 L944.8 81.8 L928.4 84.0 L920.2 86.7 L912.6 85.7 L886.0 91.4 L881.1 100.1 L888.6 99.5 L890.5 107.7 L884.9 119.4 L876.4 127.8 L869.2 131.1 L863.3 132.7 L860.2 134.4 L858.4 137.5 L854.3 139.6 L855.0 141.5 L859.6 147.8 L856.1 153.1 L851.0 153.0 L852.4 147.5 L848.8 145.1 L847.2 144.6 L847.8 142.6 L848.1 140.1 L841.3 139.9 L837.7 140.7 L837.9 136.3 L830.6 141.0 L827.9 144.3 L832.5 146.8 L839.9 146.0 L835.1 149.7 L834.0 154.6 L838.6 162.0 L837.5 166.3 L838.0 171.6 L832.2 178.5 L821.9 186.7 L816.1 187.4 L807.7 190.6 L804.5 191.6 L800.1 190.1 L793.5 197.1 L800.7 205.3 L803.3 217.6 L795.6 223.5 L791.9 222.4 L786.4 219.0 L780.1 214.9 L777.8 215.8 L775.6 224.3 L779.1 229.4 L783.7 232.7 L787.2 236.5 L787.3 240.6 L789.6 245.5 L784.9 244.5 L779.7 239.1 L778.6 233.2 L776.4 229.6 L773.2 228.3 L773.8 222.4 L773.4 216.6 L771.6 208.8 L768.1 204.4 L761.6 205.5 L759.8 196.2 L756.6 192.6 L755.1 188.4 L751.6 187.8 L749.2 189.3 L746.9 189.7 L741.8 192.4 L733.2 199.2 L728.3 204.0 L723.1 205.8 L723.0 213.9 L720.4 221.4 L717.4 225.2 L712.8 225.3 L709.4 217.3 L706.8 209.4 L702.3 196.6 L697.7 192.3 L693.5 187.6 L687.3 183.5 L679.2 179.9 L665.6 179.5 L658.3 175.1 L652.0 176.4 L643.1 172.6 L637.7 166.7 L633.3 166.7 L634.5 170.7 L637.4 174.7 L639.2 177.9 L640.7 180.6 L641.7 177.8 L643.4 180.0 L643.8 182.5 L648.3 182.9 L654.0 179.3 L656.9 176.9 L656.7 180.8 L661.5 184.0 L665.1 187.1 L665.1 189.7 L662.5 193.3 L660.2 195.2 L659.0 197.4 L656.3 200.3 L653.5 202.1 L648.8 203.6 L645.0 205.7 L637.7 209.1 L633.2 211.1 L627.4 212.9 L625.4 214.0 L622.7 215.0 L620.1 211.8 L618.3 207.7 L619.0 205.8 L617.6 202.6 L614.5 198.1 L610.6 193.5 L608.5 187.3 L604.1 182.5 L602.6 178.9 L599.0 174.0 L596.6 170.5 L597.0 168.1 L594.9 172.7 L592.0 171.1 L590.9 170.3 L595.8 178.9 L598.6 184.0 L602.4 188.9 L603.1 195.0 L606.7 200.0 L610.6 207.1 L617.4 212.9 L620.3 215.6 L619.8 218.2 L622.5 221.0 L629.6 220.0 L634.4 218.4 L638.1 217.8 L642.0 216.6 L641.8 220.4 L639.1 227.5 L632.6 238.3 L622.4 247.1 L616.1 254.0 L612.9 256.9 L610.6 260.2 L607.6 266.4 L609.6 269.7 L608.9 273.6 L612.0 278.7 L612.7 285.1 L612.4 292.8 L607.0 297.5 L599.7 302.3 L596.4 306.9 L598.3 311.5 L598.3 315.4 L597.3 318.0 L590.5 321.5 L591.2 324.3 L589.5 329.9 L585.8 333.1 L580.3 339.4 L573.4 343.4 L569.9 343.9 L563.9 344.2 L557.5 345.6 L553.3 345.7 L551.0 344.8 L549.8 340.6 L548.8 335.4 L545.4 329.4 L541.6 322.5 L540.0 312.9 L537.1 308.0 L532.8 300.2 L532.7 293.9 L534.7 287.6 L537.9 283.4 L537.2 278.8 L535.9 274.9 L535.4 269.2 L533.8 266.1 L528.0 258.2 L524.5 252.2 L526.4 247.2 L527.2 241.5 L524.3 237.9 L520.7 237.7 L516.4 238.2 L512.0 232.6 L505.2 232.9 L497.0 236.1 L490.8 236.2 L483.8 236.1 L478.6 237.9 L472.5 234.5 L467.5 230.9 L463.5 227.3 L460.9 222.5 L459.2 220.4 L456.5 218.2 L454.7 216.8 L453.2 213.5 L451.0 209.1 L454.3 205.2 L455.1 199.7 L454.8 194.2 L452.7 190.5 L454.8 187.0 L457.2 182.3 L458.9 178.8 L463.5 173.2 L469.7 169.9 L472.7 163.4 L476.0 157.7 L482.7 152.4 L487.2 151.9 L494.0 152.3 L501.4 149.2 L513.4 147.6 L520.4 146.9 L526.4 146.2 L530.6 147.0 L529.4 150.1 L528.2 154.6 L530.9 157.5 L536.3 158.7 L543.6 162.8 L553.0 165.9 L555.1 161.8 L559.8 158.8 L565.6 160.6 L569.9 162.3 L579.0 163.8 L583.6 162.6 L588.8 164.1 L593.8 164.0 L595.8 162.2 L597.5 158.1 L599.9 153.9 L600.4 150.5 L598.8 148.4 L590.3 149.7 L584.4 149.3 L576.8 148.2 L574.5 141.7 L580.1 137.6 L589.9 134.1 L602.5 135.2 L612.1 136.1 L615.1 131.5 L611.0 129.3 L601.9 124.3 L604.6 120.5 L606.2 119.2 L599.5 120.4 L598.6 123.9 L597.9 125.2 L593.2 124.9 L593.3 122.6 L588.0 120.3 L582.2 124.2 L580.1 125.2 L576.9 131.7 L580.5 135.3 L575.5 137.0 L572.4 136.6 L565.9 137.0 L564.8 139.0 L563.5 139.8 L565.4 143.0 L564.2 144.7 L564.3 148.8 L559.2 145.4 L556.2 140.7 L555.4 139.1 L553.9 135.0 L553.2 133.5 L548.6 131.0 L542.2 127.1 L541.4 124.8 L537.9 124.6 L538.7 123.4 L534.4 125.3 L537.6 128.9 L544.2 133.4 L546.6 135.6 L551.3 138.4 L546.9 137.7 L547.4 141.9 L543.6 144.7 L544.7 141.8 L541.7 138.4 L537.9 135.6 L531.1 132.3 L527.0 127.7 L521.8 128.4 L512.7 129.4 L508.4 133.6 L502.0 137.0 L500.3 142.4 L496.0 146.0 L487.9 148.1 L483.7 149.9 L479.3 146.9 L475.3 147.6 L474.2 143.4 L474.9 139.6 L475.6 135.6 L475.0 131.7 L481.2 129.0 L490.2 129.3 L496.7 122.2 L487.5 116.8 L495.5 114.9 L503.7 110.8 L509.2 107.4 L516.9 101.4 L522.0 100.7 L523.8 98.9 L522.5 92.9 L526.2 91.2 L529.3 91.1 L530.3 93.2 L526.8 95.9 L530.4 99.0 L534.8 98.7 L541.1 99.9 L551.7 98.1 L555.2 97.6 L558.6 92.3 L564.8 91.7 L567.9 87.8 L564.8 85.6 L574.9 84.9 L578.0 81.9 L563.5 83.8 L559.8 78.6 L562.3 72.7 L570.3 68.0 L558.9 69.4 L549.6 75.7 L552.2 83.1 L545.7 91.6 L539.2 96.1 L532.7 90.4 L523.3 88.0 L514.7 84.3 L523.8 73.7 L541.0 61.6 L559.4 54.8 L573.2 52.8 L583.3 55.0 L593.8 57.5 L614.1 62.6 L606.6 66.7 L596.7 66.9 L602.8 72.6 L603.3 69.0 L610.5 68.1 L622.1 66.5 L622.7 61.2 L630.1 62.0 L628.7 64.8 L639.5 61.1 L648.6 60.6 L659.2 59.8 L669.7 58.5 L676.4 56.8 L692.2 59.4 L685.9 57.1 L685.3 52.7 L694.3 47.1 L699.6 51.6 L701.6 58.3 L698.0 65.8 L705.3 64.5 L706.9 60.2 L704.4 56.6 L708.0 49.7 L710.2 49.2 L710.8 50.4 L726.4 50.7 L728.5 44.9 L738.9 43.2 L750.7 39.9 L766.3 38.5 L779.9 37.7 L789.9 34.2 L797.1 36.2 L808.5 36.9 L816.3 40.8 L803.9 43.9 L813.9 44.5 L821.0 45.1 L842.2 47.3 L852.7 45.7 L856.8 50.1 L867.4 50.5 L881.9 51.8 L886.5 48.8 L917.6 51.1 L941.7 53.1 L947.1 57.1 L960.9 57.0 L974.5 58.3 L982.3 56.1 L0.0 58.4 Z M636.4 135.3 L640.0 138.2 L636.7 141.5 L636.7 145.6 L645.2 148.1 L649.3 144.7 L648.2 139.0 L649.6 137.1 L649.2 133.0 L645.8 133.9 L645.8 131.1 L639.8 127.0 L642.5 124.3 L647.8 121.6 L642.2 119.3 L635.1 122.8 L632.2 128.7 L636.4 135.3 Z M234.3 58.0 L226.6 58.5 L227.2 55.2 L232.6 57.0 Z M0.0 51.3 L1000.0 53.2 L996.9 53.4 L996.5 52.5 L0.0 51.3 Z M248.5 57.0 L255.5 59.4 L260.3 61.3 L266.4 56.1 L274.4 59.3 L273.9 63.6 L261.8 65.1 L257.4 70.1 L248.0 73.3 L241.2 77.7 L237.0 86.3 L243.6 91.4 L255.4 93.1 L263.9 96.4 L271.0 99.2 L278.0 107.8 L280.2 99.6 L285.8 94.9 L285.3 88.7 L284.0 81.2 L289.7 77.0 L297.5 77.5 L306.7 80.4 L310.1 86.7 L318.8 83.7 L326.4 88.4 L332.0 95.1 L340.7 98.3 L345.1 102.0 L341.3 107.2 L328.5 110.9 L315.6 110.5 L305.7 117.4 L309.3 115.8 L321.7 114.6 L320.9 121.6 L331.9 119.4 L330.4 124.3 L318.4 129.0 L321.0 124.2 L314.0 125.5 L305.2 128.7 L303.3 132.4 L305.0 132.9 L303.8 134.8 L299.2 135.4 L299.3 135.8 L294.5 137.1 L294.6 137.7 L291.7 141.1 L290.8 141.8 L290.6 144.4 L289.7 144.6 L287.4 142.5 L288.1 144.7 L289.3 148.5 L285.0 154.1 L280.4 157.0 L275.4 161.0 L274.1 166.6 L276.3 172.1 L277.4 178.3 L274.5 180.0 L271.6 175.8 L270.4 170.7 L266.4 166.4 L261.7 166.2 L254.4 165.6 L251.6 167.0 L251.6 169.0 L247.6 169.0 L241.0 167.3 L234.4 170.2 L229.5 173.9 L230.2 178.1 L229.1 180.6 L228.1 187.7 L230.0 192.7 L233.6 197.7 L240.1 198.8 L246.1 197.6 L248.7 192.5 L254.0 190.3 L258.9 190.7 L256.6 195.4 L256.0 199.3 L254.7 199.0 L254.8 201.0 L254.9 202.7 L253.5 204.9 L254.1 206.0 L255.8 205.9 L257.3 206.0 L260.8 205.9 L262.7 205.9 L265.2 206.0 L267.3 207.2 L268.8 208.6 L268.3 211.2 L268.1 214.3 L267.4 217.0 L267.2 219.2 L269.4 222.2 L271.6 225.0 L273.8 225.6 L278.0 224.1 L280.4 223.7 L284.1 225.1 L288.7 224.1 L290.3 220.5 L293.9 218.6 L299.3 216.8 L302.4 216.4 L300.1 218.3 L299.8 222.6 L302.7 222.6 L305.1 218.4 L306.7 218.2 L310.6 220.7 L317.6 221.7 L321.3 220.4 L325.8 221.1 L331.0 223.9 L334.0 226.8 L337.6 231.0 L341.3 233.4 L347.1 233.3 L353.1 235.0 L357.5 238.3 L361.2 245.2 L360.0 250.2 L367.2 251.6 L376.6 255.9 L384.8 258.1 L396.6 263.4 L402.1 265.2 L402.4 275.0 L395.3 283.8 L391.8 288.3 L390.9 299.6 L386.7 308.1 L383.4 313.8 L374.0 316.1 L365.3 321.9 L364.8 328.3 L359.2 336.1 L353.6 342.2 L347.4 347.1 L341.3 345.6 L337.5 345.6 L342.4 351.1 L335.5 357.6 L327.4 359.5 L325.7 364.0 L319.1 364.1 L322.9 366.8 L318.9 370.8 L315.3 375.1 L315.0 380.6 L313.4 385.3 L308.0 390.9 L309.5 395.3 L303.2 396.9 L298.5 398.7 L290.9 393.4 L290.0 385.2 L289.9 379.6 L296.6 373.5 L295.3 370.5 L295.3 361.0 L295.6 353.2 L300.4 344.2 L301.8 333.6 L303.5 321.4 L305.1 304.9 L301.5 298.2 L288.9 290.7 L285.8 284.0 L279.3 272.0 L274.3 267.0 L274.7 261.2 L277.8 256.2 L275.7 255.5 L276.7 250.8 L279.1 247.3 L281.6 245.1 L283.5 242.5 L284.7 238.6 L285.2 233.8 L282.7 229.1 L282.1 226.7 L279.0 225.2 L276.7 226.9 L277.0 229.4 L274.8 228.3 L273.0 227.5 L269.9 227.0 L268.0 226.5 L267.7 224.9 L264.9 223.3 L264.1 222.8 L262.1 222.4 L262.1 220.1 L261.0 218.3 L257.9 215.4 L257.2 214.1 L256.1 212.8 L253.2 213.2 L249.7 211.8 L245.3 210.8 L239.2 205.7 L233.2 206.2 L227.7 205.3 L219.9 202.3 L215.3 200.1 L208.4 196.3 L207.2 193.0 L207.6 190.5 L205.5 186.7 L198.9 180.1 L196.4 176.5 L192.7 172.6 L188.3 169.6 L185.7 164.5 L182.8 162.4 L181.2 164.1 L184.5 169.3 L185.7 171.1 L187.6 173.5 L190.9 178.5 L192.6 182.5 L196.1 185.1 L194.4 186.6 L189.8 182.0 L188.1 177.7 L184.5 176.0 L180.4 173.0 L182.8 171.9 L179.1 167.9 L175.8 162.1 L172.4 156.6 L169.2 155.3 L164.9 153.9 L159.6 145.7 L156.3 141.8 L155.1 135.7 L155.2 128.6 L154.5 117.4 L158.0 116.6 L159.7 116.2 L153.0 111.2 L144.5 106.3 L140.8 101.2 L135.9 96.7 L129.1 91.2 L120.5 88.3 L108.8 84.1 L94.7 82.1 L88.8 83.4 L81.6 85.1 L79.4 81.3 L78.1 81.3 L74.2 86.5 L65.8 90.5 L59.9 94.5 L52.2 96.2 L42.3 98.9 L47.6 96.3 L55.4 93.3 L61.9 90.1 L60.6 87.2 L56.4 86.3 L51.8 87.0 L50.4 84.3 L42.6 82.6 L38.6 79.2 L42.9 74.6 L49.3 73.5 L52.9 71.6 L51.7 70.1 L45.7 70.7 L36.5 69.2 L43.1 65.1 L50.9 66.3 L43.3 62.2 L38.3 58.7 L47.4 56.0 L58.2 53.1 L69.3 52.4 L77.2 53.2 L84.1 54.1 L97.4 55.6 L108.4 56.4 L120.8 58.6 L130.8 56.9 L141.4 56.2 L146.0 54.5 L154.8 57.2 L162.6 56.1 L177.2 58.8 L179.7 61.4 L194.6 61.2 L197.7 60.2 L205.1 58.9 L213.3 60.8 L226.5 61.7 L233.0 60.4 L237.0 60.9 L232.0 55.3 L239.2 50.7 L243.3 56.4 Z M182.9 46.9 L191.5 48.7 L199.5 51.0 L201.3 46.6 L209.0 50.8 L219.5 55.5 L216.4 58.0 L205.7 57.8 L189.0 59.4 L179.9 57.6 L175.9 55.4 L187.7 54.5 L172.5 54.1 L173.2 52.0 L172.6 48.0 Z M287.9 46.9 L282.2 47.6 L275.3 46.3 L283.2 45.4 Z M259.6 46.8 L271.3 45.1 L281.2 49.0 L293.8 50.6 L302.2 53.0 L314.0 57.8 L319.8 61.5 L327.3 66.2 L314.7 65.6 L313.6 69.1 L320.4 73.9 L308.9 72.9 L316.2 78.0 L299.3 73.9 L292.1 70.3 L281.8 70.6 L294.6 68.2 L298.2 63.1 L292.1 59.6 L285.3 56.2 L279.2 55.9 L258.2 54.8 L254.3 52.2 L251.6 46.9 L259.6 46.8 Z M221.2 44.9 L230.2 45.9 L231.3 50.9 L222.2 50.7 L221.0 48.0 Z M898.9 46.6 L894.7 46.7 L889.0 46.3 L888.5 46.2 L891.1 45.1 L894.6 44.8 L898.6 45.9 L898.9 46.6 Z M241.1 47.9 L233.2 47.4 L237.5 44.1 L244.4 47.3 Z M165.4 51.7 L150.2 50.4 L155.7 45.3 L166.4 43.8 L179.1 45.9 L165.4 50.5 Z M918.7 41.4 L915.5 42.5 L911.0 42.3 L905.9 41.2 L906.5 40.3 L911.7 40.7 L918.7 41.4 Z M240.0 41.7 L238.5 42.8 L234.4 42.6 L231.1 41.9 L232.5 40.6 L236.5 39.9 L239.0 40.8 L240.0 41.7 Z M903.0 40.1 L900.8 42.2 L890.6 42.1 L886.0 42.7 L880.5 40.9 L882.0 39.0 L885.6 38.5 L893.0 38.6 L903.0 40.1 Z M226.4 36.9 L227.3 41.7 L219.8 39.9 L218.1 38.0 L226.4 36.9 Z M199.4 38.3 L205.9 39.0 L195.3 42.1 L183.7 42.4 L173.0 41.0 L187.3 38.5 L193.1 37.7 L199.4 38.3 Z M659.8 53.6 L648.4 52.2 L645.8 49.4 L648.6 45.1 L660.7 40.0 L683.9 36.6 L689.4 38.2 L662.4 43.6 L654.5 51.3 Z M237.0 35.8 L247.9 37.6 L252.3 40.0 L264.5 39.7 L277.6 40.7 L272.4 43.2 L255.1 43.4 L242.3 40.6 L233.4 37.7 L237.0 35.8 Z M177.2 34.3 L172.1 37.6 L158.7 38.6 L173.4 34.7 Z M193.9 34.2 L188.7 35.0 L184.6 34.1 L186.9 33.2 L190.9 32.9 L194.9 33.3 L193.9 34.2 Z M568.7 33.7 L562.5 34.9 L557.6 34.2 L559.5 33.5 L557.8 32.6 L563.6 32.1 L564.7 33.1 L568.7 33.7 Z M233.8 33.2 L229.7 33.8 L227.4 33.1 L226.2 32.1 L226.0 30.9 L229.6 31.0 L231.2 31.2 L234.6 32.2 L233.8 33.2 Z M222.1 32.4 L214.0 32.4 L207.2 30.8 L219.9 31.1 Z M791.9 32.5 L776.2 33.6 L781.3 29.9 L783.6 29.6 L785.7 29.8 L792.7 31.4 L791.9 32.5 Z M550.7 28.6 L551.3 33.8 L544.2 36.8 L536.6 33.3 L536.6 27.7 L543.1 27.7 Z M570.7 26.6 L564.0 29.4 L551.3 28.2 L560.9 26.8 Z M642.0 26.3 L635.4 27.3 L630.8 26.2 L634.2 25.6 L639.0 25.2 Z M777.6 30.9 L759.2 29.4 L760.5 24.9 L778.3 28.4 Z M258.3 28.7 L252.7 32.5 L239.0 31.2 L236.2 29.5 L233.3 26.1 L236.8 24.4 L251.5 26.4 Z M309.7 19.1 L328.2 20.5 L314.6 23.0 L311.6 25.3 L296.5 28.8 L290.2 30.0 L287.9 32.8 L278.4 35.5 L283.6 36.7 L260.8 38.1 L251.1 36.2 L256.5 33.4 L255.7 32.3 L263.6 29.6 L266.1 27.2 L266.4 26.2 L249.4 24.3 L249.7 22.0 L262.5 20.4 L271.1 19.8 L288.2 19.0 L303.7 19.0 Z M424.7 18.0 L426.3 21.4 L422.6 21.9 L438.7 23.0 L456.2 22.5 L454.8 26.2 L450.7 27.4 L445.4 34.3 L439.8 37.1 L442.6 41.2 L443.2 45.0 L434.5 46.4 L432.6 48.3 L438.5 51.5 L432.5 53.2 L426.8 54.9 L430.5 57.6 L411.7 60.8 L399.0 66.7 L389.4 68.2 L385.6 73.7 L380.9 80.3 L371.5 81.0 L361.4 76.7 L354.8 69.0 L350.1 63.4 L358.1 57.9 L354.0 57.2 L347.9 54.8 L357.3 54.0 L347.2 51.6 L346.3 47.3 L337.2 41.4 L323.9 38.4 L306.5 37.8 L314.5 35.1 L296.8 32.1 L318.5 28.5 L323.1 24.4 L332.6 22.1 L352.7 22.5 L370.6 22.3 L370.1 20.5 L392.7 17.9 Z";

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
    <section className="bg-bg-primary rounded-xl p-5 sm:p-6 shadow-sm space-y-5">
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
        <div
          className="relative aspect-[2/1] min-h-[260px] overflow-hidden rounded-xl border border-border-dim bg-bg-secondary shadow-inner"
          style={{
            background:
              "linear-gradient(180deg, color-mix(in srgb, var(--bg-primary) 64%, transparent), transparent 42%), radial-gradient(ellipse at 50% 36%, color-mix(in srgb, var(--accent-brand) 11%, transparent), transparent 44%), radial-gradient(ellipse at 18% 56%, color-mix(in srgb, var(--accent-green) 9%, transparent), transparent 34%), var(--bg-secondary)",
            boxShadow:
              "inset 0 1px 0 color-mix(in srgb, white 55%, transparent), inset 0 -30px 60px color-mix(in srgb, var(--text-primary) 5%, transparent)",
          }}
        >
          <div className="absolute inset-0 opacity-[0.18]">
            <div
              className="absolute inset-0"
              style={{
                backgroundImage:
                  "linear-gradient(to right, var(--border-subtle) 1px, transparent 1px), linear-gradient(to bottom, var(--border-subtle) 1px, transparent 1px)",
                backgroundSize: "72px 72px",
              }}
            />
          </div>
          <svg
            className="absolute inset-0 h-full w-full"
            viewBox="0 0 1000 500"
            preserveAspectRatio="xMidYMid meet"
            aria-hidden="true"
          >
            <defs>
              <filter id="network-dot-lift" x="-80%" y="-80%" width="260%" height="260%">
                <feDropShadow dx="0" dy="2" stdDeviation="2" floodColor="rgba(0,0,0,0.22)" />
              </filter>
              <radialGradient id="consumer-dot-fill" cx="32%" cy="28%" r="78%">
                <stop offset="0%" stopColor="rgba(255,255,255,0.78)" />
                <stop offset="38%" stopColor="var(--accent-green)" />
                <stop offset="100%" stopColor="color-mix(in srgb, black 18%, var(--accent-green))" />
              </radialGradient>
              <radialGradient id="demand-dot-fill" cx="32%" cy="28%" r="78%">
                <stop offset="0%" stopColor="rgba(255,255,255,0.82)" />
                <stop offset="40%" stopColor="var(--accent-amber)" />
                <stop offset="100%" stopColor="color-mix(in srgb, black 18%, var(--accent-amber))" />
              </radialGradient>
            </defs>
            <g
              stroke="var(--border-subtle)"
              strokeWidth="1"
              vectorEffect="non-scaling-stroke"
              opacity="0.42"
            >
              {[125, 250, 375].map((y) => (
                <line key={`lat-${y}`} x1="50" x2="950" y1={y} y2={y} />
              ))}
              {[250, 500, 750].map((x) => (
                <line key={`lon-${x}`} x1={x} x2={x} y1="48" y2="452" />
              ))}
            </g>
            <g
              fill="color-mix(in srgb, var(--accent-brand) 5%, var(--bg-elevated))"
              stroke="color-mix(in srgb, var(--text-tertiary) 34%, transparent)"
              strokeWidth="0.85"
              vectorEffect="non-scaling-stroke"
              opacity="0.9"
            >
              <path d={WORLD_LAND_PATH} />
            </g>
            <g
              fill="none"
              stroke="var(--accent-brand)"
              strokeWidth="1"
              vectorEffect="non-scaling-stroke"
              opacity="0.14"
            >
              <path d="M118 207 C259 170 414 167 557 191 C683 213 789 246 899 236" />
              <path d="M296 278 C391 236 507 221 620 241 C710 257 786 294 854 344" />
            </g>
            <g fill="none" strokeLinecap="round">
              {requestFlows.map((flow, index) => {
                const path = flowPath(flow.from, flow.to);
                const width = Math.min(2.4, 0.75 + Math.sqrt(flow.requests) / 42);
                return (
                  <path
                    key={flow.key}
                    d={path}
                    stroke={index % 3 === 0 ? "var(--accent-brand)" : "var(--accent-green)"}
                    strokeWidth={width}
                    strokeOpacity={Math.max(0.16, 0.42 - index * 0.012)}
                    vectorEffect="non-scaling-stroke"
                  />
                );
              })}
            </g>
            <g>
              {requestFlows.slice(0, 14).map((flow, index) => {
                const path = flowPath(flow.from, flow.to);
                return (
                  <path
                    key={`${flow.key}-pulse`}
                    className="network-flow-ping"
                    d={path}
                    fill="none"
                    stroke={index % 3 === 0 ? "var(--accent-brand)" : "var(--accent-green)"}
                    strokeWidth={index < 5 ? 2.4 : 1.8}
                    strokeLinecap="round"
                    strokeDasharray="0.1 44"
                    strokeOpacity="0.92"
                    vectorEffect="non-scaling-stroke"
                    style={{
                      animationDuration: `${3.4 + (index % 5) * 0.42}s`,
                      animationDelay: `${index * -0.28}s`,
                    }}
                  />
                );
              })}
            </g>
            <g>
              {consumerPlotted.map((bucket) => {
                const point = projectedPoint(bucket);
                const demandOnly = !hasLocalProvider(bucket);
                const size = Math.min(8.5, 3 + Math.sqrt(bucket.requests) / 28);
                return (
                  <g key={`consumer-${bucket.key}`} transform={`translate(${point.x * 10} ${point.y * 5})`}>
                    <circle
                      r={size + (demandOnly ? 7 : 5)}
                      fill={demandOnly ? "var(--accent-amber)" : "var(--accent-green)"}
                      opacity={demandOnly ? "0.16" : "0.11"}
                    />
                    {demandOnly && (
                      <circle
                        r={size + 3.5}
                        fill="none"
                        stroke="var(--accent-amber)"
                        strokeDasharray="3 5"
                        strokeOpacity="0.52"
                        strokeWidth="1.4"
                        vectorEffect="non-scaling-stroke"
                      />
                    )}
                    <circle
                      r={size}
                      fill={demandOnly ? "url(#demand-dot-fill)" : "url(#consumer-dot-fill)"}
                      stroke="var(--bg-primary)"
                      strokeWidth="2"
                      filter="url(#network-dot-lift)"
                    />
                    <circle
                      r={Math.max(1.8, size * 0.28)}
                      cx={-size * 0.18}
                      cy={-size * 0.2}
                      fill="rgba(255,255,255,0.52)"
                    />
                  </g>
                );
              })}
            </g>
          </svg>

          <div className="pointer-events-none absolute left-4 top-4 z-30 flex flex-wrap items-center gap-2 rounded-lg border border-border-dim bg-bg-primary/90 px-3 py-2 shadow-sm backdrop-blur">
            <span className="flex items-center gap-1.5 text-[11px] font-mono text-text-tertiary">
              <span className="h-2.5 w-2.5 rounded-full bg-accent-green" />
              consumers
            </span>
            <span className="flex items-center gap-1.5 text-[11px] font-mono text-text-tertiary">
              <span className="h-2.5 w-2.5 rotate-45 rounded-sm bg-accent-brand" />
              providers
            </span>
            <span className="text-[11px] font-mono text-text-tertiary">
              live pings
            </span>
          </div>

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
            fallbackPlotted.map((bucket) => {
              const point = projectedPoint(bucket);
              const size = Math.min(22, 8 + Math.sqrt(bucket.providers) * 3);
              const tooltipBelow = point.y < 36;
              const attestedPct = bucket.providers > 0
                ? Math.round((bucket.hardware_attested / bucket.providers) * 100)
                : 0;
              return (
                <div
                  key={bucket.key}
                  className="group absolute z-20 -translate-x-1/2 -translate-y-1/2 hover:z-50"
                  style={{ left: `${point.x}%`, top: `${point.y}%` }}
                >
                  <span
                    className="absolute left-1/2 top-1/2 -z-10 h-3 w-8 -translate-x-1/2 translate-y-2 rounded-full bg-text-primary/10 blur-[2px]"
                    style={{ transform: `translate(-50%, ${Math.max(9, size * 0.44)}px) scale(${Math.max(0.75, size / 18)})` }}
                  />
                  <span
                    className="absolute left-1/2 top-1/2 -z-10 rounded-full border border-accent-brand/20 bg-accent-brand/10"
                    style={{
                      width: `${size + 18}px`,
                      height: `${size + 18}px`,
                      transform: "translate(-50%, -50%)",
                      boxShadow:
                        "0 0 26px color-mix(in srgb, var(--accent-brand) 16%, transparent)",
                    }}
                  />
                  <div
                    className="relative rotate-45 rounded-md border-2 border-bg-primary shadow-lg shadow-black/10 transition-transform duration-200 group-hover:scale-110"
                    style={{
                      width: `${size}px`,
                      height: `${size}px`,
                      background:
                        "linear-gradient(135deg, color-mix(in srgb, white 32%, var(--accent-brand)), var(--accent-brand) 46%, color-mix(in srgb, black 20%, var(--accent-brand)))",
                      boxShadow: `0 0 0 ${Math.max(3, Math.round(size / 4))}px color-mix(in srgb, var(--accent-brand) 10%, transparent), 0 10px 18px color-mix(in srgb, var(--accent-brand) 24%, transparent), inset -2px -2px 5px color-mix(in srgb, black 20%, transparent), inset 2px 2px 5px color-mix(in srgb, white 28%, transparent)`,
                    }}
                  >
                    <span className="absolute inset-[24%] rounded-sm bg-white/20 shadow-inner" />
                    <span className="absolute left-[12%] top-[12%] h-[26%] w-[26%] rounded-full bg-white/35 blur-[1px]" />
                  </div>
                  <div
                    className={`pointer-events-none absolute left-1/2 z-50 hidden -translate-x-1/2 group-hover:block ${
                      tooltipBelow ? "top-full mt-3" : "bottom-full mb-3"
                    }`}
                  >
                    <div className="min-w-[190px] rounded-lg bg-text-primary px-3 py-2 text-bg-primary shadow-lg">
                      <p className="text-xs font-semibold">{formatPlace(bucket)}</p>
                      <p className="text-[11px] font-mono opacity-80 mt-1">
                        {bucket.providers} nodes / {attestedPct}% attested / {bucket.gpu_cores} GPU cores
                      </p>
                    </div>
                  </div>
                </div>
              );
            })
          )}
        </div>

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
    <section className="bg-bg-primary rounded-xl p-5 sm:p-6 shadow-sm space-y-5">
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
          className="relative min-h-[300px] overflow-hidden rounded-lg border border-border-dim bg-bg-secondary shadow-inner"
          style={{
            background:
              "radial-gradient(circle at 50% 42%, color-mix(in srgb, var(--accent-green) 8%, transparent), transparent 46%), var(--bg-secondary)",
          }}
        >
          <div className="absolute inset-0 opacity-[0.16]">
            <div
              className="absolute inset-0"
              style={{
                backgroundImage:
                  "linear-gradient(to right, var(--border-subtle) 1px, transparent 1px), linear-gradient(to bottom, var(--border-subtle) 1px, transparent 1px)",
                backgroundSize: "72px 72px",
              }}
            />
          </div>
          <svg
            className="absolute inset-0 h-full w-full"
            viewBox="0 0 1000 500"
            preserveAspectRatio="none"
            aria-hidden="true"
          >
            <path
              d={WORLD_LAND_PATH}
              fill="color-mix(in srgb, var(--accent-green) 5%, var(--bg-elevated))"
              stroke="color-mix(in srgb, var(--text-tertiary) 28%, transparent)"
              strokeWidth="0.85"
              vectorEffect="non-scaling-stroke"
              opacity="0.86"
            />
            <path
              d="M118 207 C259 170 414 167 557 191 C683 213 789 246 899 236"
              fill="none"
              stroke="var(--accent-green)"
              strokeWidth="1"
              vectorEffect="non-scaling-stroke"
              opacity="0.14"
            />
          </svg>

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
    <div className="bg-bg-primary rounded-xl p-5 space-y-4 shadow-sm">
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
    <div className="bg-bg-primary rounded-xl p-5 space-y-4 shadow-sm">
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

function LeaderboardSection() {
  const [metric, setMetric] = useState<LeaderboardMetric>("earnings");
  const [window, setWindow] = useState<LeaderboardWindow>("7d");
  const [leaderboard, setLeaderboard] = useState<LeaderboardResponse | null>(null);
  const [totals, setTotals] = useState<NetworkTotalsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const windowOptions: Array<{ value: LeaderboardWindow; label: string }> = [
    { value: "24h", label: "24h" },
    { value: "7d", label: "7d" },
    { value: "30d", label: "30d" },
    { value: "all", label: "All" },
  ];
  const metricOptions: Array<{ value: LeaderboardMetric; label: string }> = [
    { value: "earnings", label: "Earnings" },
    { value: "tokens", label: "Tokens" },
    { value: "jobs", label: "Jobs" },
  ];

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    async function loadLeaderboard() {
      try {
        const [nextLeaderboard, nextTotals] = await Promise.all([
          fetchLeaderboard(metric, window),
          fetchNetworkTotals(window),
        ]);
        if (cancelled) return;
        setLeaderboard(nextLeaderboard);
        setTotals(nextTotals);
      } catch (err: unknown) {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load leaderboard");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    void loadLeaderboard();

    return () => {
      cancelled = true;
    };
  }, [metric, window]);

  const entries = leaderboard?.entries ?? [];
  const podium = entries.slice(0, 3);
  const updatedAt = leaderboard?.updated_at
    ? new Date(leaderboard.updated_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : "";

  return (
    <section className="space-y-5">
      <div className="rounded-xl border border-border-dim bg-bg-primary p-5 shadow-sm">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="flex items-center gap-2">
              <Trophy size={16} className="text-accent-brand" />
              <h2 className="text-sm font-semibold text-text-primary">Provider Earnings Leaderboard</h2>
            </div>
            <p className="mt-1 max-w-2xl text-xs text-text-tertiary">
              Pseudonymized provider accounts ranked from the coordinator leaderboard.
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <Link
              href="/providers/setup"
              className="inline-flex items-center gap-1.5 rounded-lg bg-accent-brand px-3 py-1.5 text-sm font-semibold text-bg-primary shadow-sm transition-colors hover:bg-accent-brand/90"
            >
              <Zap size={14} />
              Earn Now
            </Link>
            {windowOptions.map((option) => (
              <button
                key={option.value}
                type="button"
                onClick={() => setWindow(option.value)}
                className={`rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors ${
                  window === option.value
                    ? "border-accent-brand/35 bg-accent-brand/10 text-accent-brand"
                    : "border-border-dim bg-bg-secondary text-text-secondary hover:border-border-subtle hover:bg-bg-hover"
                }`}
              >
                {option.label}
              </button>
            ))}
          </div>
        </div>

        <div className="mt-5 grid grid-cols-2 gap-3 md:grid-cols-4">
          <LeaderboardTotal
            icon={<CircleDollarSign size={14} />}
            label="Provider earnings"
            value={totals ? formatUSDFromMicro(totals.earnings_micro_usd) : "--"}
          />
          <LeaderboardTotal
            icon={<BarChart3 size={14} />}
            label="Tokens served"
            value={totals ? formatNumber(totals.tokens) : "--"}
          />
          <LeaderboardTotal
            icon={<Activity size={14} />}
            label="Jobs"
            value={totals ? formatNumber(totals.jobs) : "--"}
          />
          <LeaderboardTotal
            icon={<Users size={14} />}
            label="Active accounts"
            value={totals ? formatNumber(totals.active_accounts) : "--"}
          />
        </div>
      </div>

      <div className="rounded-xl border border-border-dim bg-bg-primary p-5 shadow-sm">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h3 className="text-sm font-semibold text-text-primary">Rankings</h3>
            <p className="mt-1 text-xs text-text-tertiary">
              {updatedAt ? `Updated ${updatedAt}` : "Fresh values load from the coordinator"}
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            {metricOptions.map((option) => (
              <button
                key={option.value}
                type="button"
                onClick={() => setMetric(option.value)}
                className={`rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors ${
                  metric === option.value
                    ? "border-accent-green/35 bg-accent-green/10 text-accent-green"
                    : "border-border-dim bg-bg-secondary text-text-secondary hover:border-border-subtle hover:bg-bg-hover"
                }`}
              >
                {option.label}
              </button>
            ))}
          </div>
        </div>

        {loading ? (
          <div className="mt-8 flex items-center justify-center py-12 text-text-tertiary">
            <Loader2 size={22} className="animate-spin" />
          </div>
        ) : error ? (
          <div className="mt-5 rounded-xl border border-accent-red/20 bg-accent-red/5 p-5 text-sm text-accent-red">
            {error}
          </div>
        ) : entries.length === 0 ? (
          <div className="mt-5 rounded-xl border border-dashed border-border-dim bg-bg-secondary p-8 text-center text-sm text-text-tertiary">
            No leaderboard activity for this window yet.
          </div>
        ) : (
          <>
            <div className="mt-5 grid gap-3 md:grid-cols-3">
              {podium.map((entry) => (
                <LeaderboardPodiumCard key={entry.rank} entry={entry} metric={metric} />
              ))}
            </div>

            <div className="mt-5 overflow-x-auto rounded-xl border border-border-dim">
              <div className="min-w-[620px]">
                <div className="grid grid-cols-[64px_minmax(0,1fr)_120px_100px_90px] gap-3 bg-bg-secondary px-4 py-2.5 text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
                  <span>Rank</span>
                  <span>Provider</span>
                  <span className="text-right">Earnings</span>
                  <span className="text-right">Tokens</span>
                  <span className="text-right">Jobs</span>
                </div>
                {entries.map((entry) => (
                  <div
                    key={`${entry.rank}-${entry.pseudonym}`}
                    className="grid grid-cols-[64px_minmax(0,1fr)_120px_100px_90px] gap-3 border-t border-border-dim px-4 py-3 text-sm"
                  >
                    <span className="font-mono font-semibold text-text-primary">#{entry.rank}</span>
                    <span className="truncate font-mono text-text-secondary">{entry.pseudonym}</span>
                    <span className="text-right font-mono font-semibold text-text-primary">
                      {formatUSDFromMicro(entry.earnings_micro_usd)}
                    </span>
                    <span className="text-right font-mono text-text-secondary">{formatNumber(entry.tokens)}</span>
                    <span className="text-right font-mono text-text-secondary">{formatNumber(entry.jobs)}</span>
                  </div>
                ))}
              </div>
            </div>
          </>
        )}
      </div>
    </section>
  );
}

function LeaderboardTotal({
  icon,
  label,
  value,
}: {
  icon: ReactNode;
  label: string;
  value: string;
}) {
  return (
    <div className="rounded-xl border border-border-dim bg-bg-secondary px-4 py-3">
      <div className="flex items-center gap-2 text-text-tertiary">
        {icon}
        <p className="text-[10px] font-mono uppercase tracking-wider">{label}</p>
      </div>
      <p className="mt-2 text-xl font-mono font-bold text-text-primary">{value}</p>
    </div>
  );
}

function leaderboardRankTone(rank: number): string {
  if (rank === 1) return "border-accent-brand/35 bg-accent-brand/10 text-accent-brand";
  if (rank === 2) return "border-accent-green/30 bg-accent-green/10 text-accent-green";
  return "border-accent-amber/30 bg-accent-amber-dim text-accent-amber";
}

function LeaderboardPodiumCard({
  entry,
  metric,
}: {
  entry: LeaderboardEntry;
  metric: LeaderboardMetric;
}) {
  const rankTone = leaderboardRankTone(entry.rank);

  return (
    <div className="rounded-xl border border-border-dim bg-bg-secondary p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate font-mono text-sm font-semibold text-text-primary">
            {entry.pseudonym}
          </p>
          <p className="mt-1 text-xs font-mono text-text-tertiary">
            {formatUSDFromMicro(entry.earnings_micro_usd)} / {formatNumber(entry.tokens)} tokens
          </p>
        </div>
        <span className={`rounded-lg border px-2 py-1 text-xs font-mono font-bold ${rankTone}`}>
          #{entry.rank}
        </span>
      </div>
      <p className="mt-4 text-2xl font-mono font-bold text-text-primary">
        {formatLeaderboardValue(entry, metric)}
      </p>
      <p className="mt-1 text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
        Ranked by {metric}
      </p>
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
    <section className="rounded-xl border border-border-dim bg-bg-primary p-5 shadow-sm">
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
  const [activeTab, setActiveTab] = useState<StatsTab>("overview");
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

  useEffect(() => {
    fetchStats();
    const interval = setInterval(fetchStats, 10_000);
    return () => clearInterval(interval);
  }, []);

  if (loading) {
    return (
      <div className="flex-1 flex flex-col">
        <TopBar title="Network Stats" />
        <div className="flex-1 flex items-center justify-center">
          <Loader2 size={24} className="animate-spin text-text-tertiary" />
        </div>
      </div>
    );
  }

  if (error || !stats) {
    return (
      <div className="flex-1 flex flex-col">
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
  const visibleModelCount = buildModelInventory(stats, catalogData?.aliases ?? []).length;
  const networkPowerWatts = activeNetworkPowerWatts(stats);
  const tabs: Array<{ value: StatsTab; label: string }> = [
    { value: "overview", label: "Overview" },
    { value: "leaderboard", label: "Leaderboard" },
  ];

  return (
    <div className="flex-1 flex flex-col overflow-y-auto">
      <TopBar title="Network Stats" />
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

        <div className="flex flex-wrap gap-2 rounded-xl border border-border-dim bg-bg-primary p-1.5 shadow-sm">
          {tabs.map((tab) => (
            <button
              key={tab.value}
              type="button"
              onClick={() => setActiveTab(tab.value)}
              className={`flex min-h-9 flex-1 items-center justify-center rounded-lg px-4 text-sm font-medium transition-colors sm:flex-none ${
                activeTab === tab.value
                  ? "bg-accent-brand text-bg-primary shadow-sm"
                  : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"
              }`}
            >
              {tab.label}
            </button>
          ))}
        </div>

        {activeTab === "leaderboard" ? (
          <LeaderboardSection />
        ) : (
          <>
        {/* Hero section -- big numbers */}
        <div className="bg-bg-primary rounded-2xl p-8 shadow-sm">
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
          <div className="bg-bg-primary rounded-xl p-5 space-y-3 shadow-sm">
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
          </>
        )}

        {/* Footer */}
        <div className="text-center pb-8">
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest">
            Auto-refreshes every 10 seconds
          </p>
        </div>
      </div>
    </div>
  );
}
