"use client";

import { useEffect, useState } from "react";
import {
  ShieldCheck,
  Shield,
  Layers,
  Loader2,
  RefreshCw,
} from "lucide-react";
import { TopBar } from "@/components/TopBar";
import { useTranslations } from "next-intl";

const STATS_API = "https://api.darkbloom.dev";

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
}

interface ModelStats {
  id: string;
  providers: number;
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
  providers: ProviderStats[];
  models: ModelStats[];
  time_series: TimeSeriesBucket[];
}

function formatNumber(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return n.toLocaleString();
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
  const t = useTranslations("StatsPage");
  if (level === "hardware") {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-green/10 border border-accent-green/20 text-accent-green text-xs font-medium uppercase tracking-wider">
        <ShieldCheck size={10} />
        {t("hardware")}
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-bg-elevated border border-border-subtle text-text-tertiary text-xs font-medium uppercase tracking-wider">
      <Shield size={10} />
      {t("none")}
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
    <div className="px-4 py-3 bg-bg-secondary rounded-lg shadow-sm text-center">
      <p className="text-lg font-mono font-bold text-text-primary">{value}</p>
      <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
        {label}
      </p>
      {sub && (
        <p className="text-xs font-mono text-text-tertiary mt-0.5">{sub}</p>
      )}
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
  formatValue,
}: {
  data: TimeSeriesBucket[];
  label: string;
  color: string;
  getValue: (d: TimeSeriesBucket) => number;
  formatValue?: (n: number) => string;
}) {
  const t = useTranslations("StatsPage");
  const values = data.map(getValue);
  const max = Math.max(...values, 1);
  const hasData = values.some((v) => v > 0);
  const fmt = formatValue || formatNumber;

  return (
    <div className="bg-bg-primary rounded-xl p-5 space-y-3 shadow-sm">
      <div className="flex items-center justify-between">
        <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
          {label}
        </h3>
        {data.length > 0 && (
          <span className="text-xs font-mono text-text-tertiary">
            {t("lastMinutes", { count: data.length })}
          </span>
        )}
      </div>
      <div className="flex items-end gap-[2px] h-28">
        {!hasData ? (
          <div className="flex-1 flex flex-col items-center justify-center gap-2">
            <div className="flex gap-1">
              {Array.from({ length: 20 }).map((_, i) => (
                <div
                  key={i}
                  className="w-2 rounded-t-sm"
                  style={{
                    height: `${8 + Math.sin(i * 0.7) * 6}px`,
                    background: color,
                    opacity: 0.12,
                  }}
                />
              ))}
            </div>
            <p className="text-xs font-mono text-text-tertiary">
              {t("activityPlaceholder")}
            </p>
          </div>
        ) : (
          values.map((v, i) => {
            const pct = (v / max) * 100;
            const ts = data[i].timestamp;
            const time = ts
              ? new Date(ts).toLocaleTimeString([], {
                  hour: "2-digit",
                  minute: "2-digit",
                })
              : "";
            return (
              <div
                key={i}
                className="flex-1 group relative flex flex-col justify-end"
              >
                <div
                  className="rounded-t-sm transition-all duration-300"
                  style={{
                    height: `${Math.max(pct, v > 0 ? 4 : 2)}%`,
                    background: v > 0 ? color : "var(--border-dim)",
                    opacity: v > 0 ? 0.7 : 0.2,
                  }}
                />
                <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block z-10">
                  <div className="bg-text-primary text-bg-primary text-xs font-mono px-2 py-1 rounded shadow-lg whitespace-nowrap">
                    {fmt(v)} &middot; {time}
                  </div>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Stacked token chart
// ---------------------------------------------------------------------------
function TokenChart({ data }: { data: TimeSeriesBucket[] }) {
  const t = useTranslations("StatsPage");
  const hasData = data.some(
    (d) => d.prompt_tokens + d.completion_tokens > 0
  );
  const maxTokens = Math.max(
    ...data.map((d) => d.prompt_tokens + d.completion_tokens),
    1
  );

  return (
    <div className="bg-bg-primary rounded-xl p-5 space-y-3 shadow-sm">
      <div className="flex items-center justify-between">
        <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
          {t("tokensPerMinute")}
        </h3>
        <div className="flex items-center gap-3">
          <span className="flex items-center gap-1 text-xs font-mono text-text-tertiary">
            <span className="w-2 h-2 rounded-sm" style={{ background: "var(--accent-brand)" }} />
            {t("input")}
          </span>
          <span className="flex items-center gap-1 text-xs font-mono text-text-tertiary">
            <span className="w-2 h-2 rounded-sm" style={{ background: "var(--accent-green)" }} />
            {t("output")}
          </span>
        </div>
      </div>
      <div className="flex items-end gap-[2px] h-28">
        {!hasData ? (
          <div className="flex-1 flex flex-col items-center justify-center gap-2">
            <div className="flex gap-1">
              {Array.from({ length: 20 }).map((_, i) => (
                <div key={i} className="flex flex-col justify-end">
                  <div
                    className="w-2 rounded-t-sm"
                    style={{
                      height: `${4 + Math.cos(i * 0.5) * 3}px`,
                      background: "var(--accent-green)",
                      opacity: 0.12,
                    }}
                  />
                  <div
                    className="w-2"
                    style={{
                      height: `${3 + Math.sin(i * 0.8) * 2}px`,
                      background: "var(--accent-brand)",
                      opacity: 0.12,
                    }}
                  />
                </div>
              ))}
            </div>
            <p className="text-xs font-mono text-text-tertiary">
              {t("tokenPlaceholder")}
            </p>
          </div>
        ) : (
          data.map((d, i) => {
            const total = d.prompt_tokens + d.completion_tokens;
            const pctTotal = (total / maxTokens) * 100;
            const pctPrompt = total > 0 ? (d.prompt_tokens / total) * pctTotal : 0;
            const pctCompletion = total > 0 ? (d.completion_tokens / total) * pctTotal : 0;
            return (
              <div key={i} className="flex-1 group relative flex flex-col justify-end">
                <div
                  className="rounded-t-sm transition-all duration-300"
                  style={{
                    height: `${Math.max(pctCompletion, total > 0 ? 2 : 0)}%`,
                    background: "var(--accent-green)",
                    opacity: 0.7,
                  }}
                />
                <div
                  className="transition-all duration-300"
                  style={{
                    height: `${Math.max(pctPrompt, total > 0 ? 2 : 0)}%`,
                    background: "var(--accent-brand)",
                    opacity: 0.7,
                  }}
                />
                {total === 0 && (
                  <div className="min-h-[2px]" style={{ background: "var(--border-dim)", opacity: 0.3 }} />
                )}
                <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block z-10">
                  <div className="bg-text-primary text-bg-primary text-xs font-mono px-2 py-1 rounded shadow-lg whitespace-nowrap">
                    {t("tokenTooltip", {
                      input: formatNumber(d.prompt_tokens),
                      output: formatNumber(d.completion_tokens),
                    })}
                  </div>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Provider card
// ---------------------------------------------------------------------------
function ProviderCard({ provider }: { provider: ProviderStats }) {
  const t = useTranslations("StatsPage");
  return (
    <div className="bg-bg-primary rounded-xl p-5 shadow-sm hover:shadow-md transition-shadow">
      {/* Header */}
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-center gap-3">
          <StatusDot status={provider.status} />
          <div>
            <p className="text-sm font-semibold text-text-primary">
              {provider.chip}
            </p>
            <p className="text-xs font-mono text-text-tertiary">
              {provider.machine_model} &middot; {provider.id.slice(0, 8)}...
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <TrustBadge level={provider.trust_level} />
          <span
            className={`px-2 py-0.5 rounded-full text-xs font-mono uppercase tracking-wider ${
              provider.status === "serving"
                ? "bg-accent-brand/10 border border-accent-brand/20 text-accent-brand"
                : provider.status === "online"
                ? "bg-accent-green/10 border border-accent-green/20 text-accent-green"
                : "bg-bg-elevated border border-border-subtle text-text-tertiary"
            }`}
          >
            {provider.status}
          </span>
        </div>
      </div>

      {/* Specs grid */}
      <div className="grid grid-cols-3 md:grid-cols-6 gap-3">
        <div>
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-0.5">{t("memory")}</p>
          <p className="text-sm font-mono font-semibold text-text-primary">{provider.memory_gb} GB</p>
        </div>
        <div>
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-0.5">{t("gpu")}</p>
          <p className="text-sm font-mono font-semibold text-text-primary">{provider.gpu_cores}-core</p>
        </div>
        <div>
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-0.5">{t("cpu")}</p>
          <p className="text-sm font-mono font-semibold text-text-primary">
            {provider.cpu_cores.performance}P + {provider.cpu_cores.efficiency}E
          </p>
        </div>
        <div>
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-0.5">{t("bandwidth")}</p>
          <p className="text-sm font-mono font-semibold text-text-primary">
            {provider.memory_bandwidth_gbs} GB/s
          </p>
        </div>
        <div>
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-0.5">{t("requests")}</p>
          <p className="text-sm font-mono font-semibold text-text-primary">
            {formatNumber(provider.requests_served)}
          </p>
        </div>
        <div>
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-0.5">{t("tokens")}</p>
          <p className="text-sm font-mono font-semibold text-text-primary">
            {formatNumber(provider.tokens_generated)}
          </p>
        </div>
      </div>

      {(provider.models?.length || provider.current_model) && (
        <div className="mt-3 pt-3 border-t border-border-dim">
          {provider.current_model && (
            <p className="text-xs font-mono text-text-tertiary">
              {t("serving")} <span className="text-text-secondary">{provider.current_model.split("/").pop()}</span>
            </p>
          )}
          {provider.models && provider.models.length > 0 && (
            <div className="mt-1.5 flex flex-wrap gap-1">
              {provider.models.map((m) => (
                <span key={m} className={`text-[10px] font-mono px-1.5 py-0.5 rounded ${m === provider.current_model ? 'bg-accent/10 text-accent' : 'bg-bg-secondary text-text-tertiary'}`}>
                  {m.split("/").pop()}
                </span>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------
export default function StatsPage() {
  const [stats, setStats] = useState<PlatformStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const t = useTranslations("StatsPage");

  const fetchStats = async () => {
    try {
      const res = await fetch(`${STATS_API}/v1/stats`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setStats(data);
      setError(null);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : t("failedFetch"));
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
        <TopBar title={t("title")} />
        <div className="flex-1 flex items-center justify-center">
          <Loader2 size={24} className="animate-spin text-text-tertiary" />
        </div>
      </div>
    );
  }

  if (error || !stats) {
    return (
      <div className="flex-1 flex flex-col">
        <TopBar title={t("title")} />
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center space-y-2">
            <p className="text-text-secondary text-sm">{t("failedLoad")}</p>
            <p className="text-text-tertiary text-xs font-mono">{error}</p>
            <button onClick={fetchStats} className="mt-3 px-3 py-1.5 rounded-lg border border-border-subtle text-text-secondary text-xs hover:bg-bg-hover transition-colors">
              {t("retry")}
            </button>
          </div>
        </div>
      </div>
    );
  }

  const hardwareAttested = stats.providers.filter((p) => p.trust_level === "hardware").length;

  return (
    <div className="flex-1 flex flex-col overflow-y-auto">
      <TopBar title={t("title")} />
      <div className="max-w-5xl mx-auto px-3 sm:px-6 py-6 sm:py-8 space-y-6">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold text-text-primary tracking-tight">
              {t("heading")}
            </h1>
            <p className="text-sm text-text-tertiary mt-1">
              {t("description")}
            </p>
          </div>
          <div className="flex items-center gap-3">
            <div className="flex items-center gap-1.5">
              <span className="relative flex h-2 w-2">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent-green opacity-40" />
                <span className="relative inline-flex rounded-full h-2 w-2 bg-accent-green" />
              </span>
              <span className="text-xs font-mono text-accent-green uppercase tracking-wider">{t("live")}</span>
            </div>
            <button onClick={fetchStats} className="p-2 rounded-lg border border-border-dim hover:border-border-subtle hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-all">
              <RefreshCw size={14} />
            </button>
          </div>
        </div>

        {/* Hero section -- big numbers */}
        <div className="bg-bg-primary rounded-2xl p-8 shadow-sm">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-8">
            <HeroStat
              value={formatNumber(stats.total_tokens)}
              label={t("tokensServed")}
              sub={t("tokensInOut", {
                input: formatNumber(stats.total_prompt_tokens),
                output: formatNumber(stats.total_completion_tokens),
              })}
            />
            <HeroStat
              value={formatNumber(stats.total_requests)}
              label={t("requests")}
            />
            <HeroStat
              value={stats.active_providers.toString()}
              label={t("nodesOnline")}
              sub={hardwareAttested === stats.active_providers ? t("allHardwareAttested") : t("hardwareAttestedCount", { count: hardwareAttested })}
            />
            <HeroStat
              value={`${Math.round(stats.total_bandwidth_gbs)}`}
              label={t("gbBandwidth")}
              sub={t("combinedThroughput")}
            />
          </div>
        </div>

        {/* Hardware capacity grid */}
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-5 gap-3">
          <MiniStat label={t("gpuCores")} value={stats.total_gpu_cores.toString()} sub="Apple Silicon" />
          <MiniStat label={t("cpuCores")} value={stats.total_cpu_cores.toString()} sub={t("pECores")} />
          <MiniStat label={t("unifiedRam")} value={`${stats.total_memory_gb} GB`} />
          <MiniStat
            label={t("avgTokReq")}
            value={stats.avg_tokens_per_request > 0 ? stats.avg_tokens_per_request.toFixed(0) : "--"}
          />
          <MiniStat
            label={t("models")}
            value={stats.models.length.toString()}
            sub={stats.models.map((m) => m.id.split("/").pop()?.replace(/-/g, " ")).join(", ")}
          />
        </div>

        {/* Charts */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <ActivityChart
            data={stats.time_series}
            label={t("requestsPerMinute")}
            color="var(--accent-brand)"
            getValue={(d) => d.requests}
          />
          <TokenChart data={stats.time_series} />
        </div>

        {/* Token distribution bar (only if there are tokens) */}
        {stats.total_tokens > 0 && (
          <div className="bg-bg-primary rounded-xl p-5 space-y-3 shadow-sm">
            <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
              {t("tokenDistribution")}
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
                {t("inputPercent", {
                  value: formatNumber(stats.total_prompt_tokens),
                  percent: ((stats.total_prompt_tokens / stats.total_tokens) * 100).toFixed(0),
                })}
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
                {t("outputPercent", {
                  value: formatNumber(stats.total_completion_tokens),
                  percent: ((stats.total_completion_tokens / stats.total_tokens) * 100).toFixed(0),
                })}
              </div>
            </div>
          </div>
        )}

        {/* Models */}
        {stats.models.length > 0 && (
          <div className="bg-bg-primary rounded-xl p-5 space-y-4 shadow-sm">
            <h3 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
              {t("activeModels")}
            </h3>
            <div className="space-y-2">
              {stats.models.map((model) => (
                <div
                  key={model.id}
                  className="flex items-center justify-between px-4 py-3 bg-bg-secondary rounded-lg shadow-sm"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-8 h-8 rounded-lg bg-accent-brand/10 border border-accent-brand/20 flex items-center justify-center">
                      <Layers size={14} className="text-accent-brand" />
                    </div>
                    <div>
                      <p className="text-sm font-mono text-text-primary font-medium">
                        {model.id.split("/").pop()}
                      </p>
                      <p className="text-xs font-mono text-text-tertiary">{model.id}</p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className="text-sm font-mono text-text-primary font-semibold">{model.providers}</p>
                    <p className="text-xs font-mono text-text-tertiary">
                      {t("nodes", { count: model.providers })}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Network nodes */}
        <div className="space-y-4">
          <h2 className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
            {t("networkNodes")}
          </h2>
          <div className="grid gap-4">
            {stats.providers.map((provider) => (
              <ProviderCard key={provider.id} provider={provider} />
            ))}
          </div>
        </div>

        {/* Footer */}
        <div className="text-center pb-8">
          <p className="text-xs font-mono text-text-tertiary uppercase tracking-widest">
            {t("autoRefresh")}
          </p>
        </div>
      </div>
    </div>
  );
}
