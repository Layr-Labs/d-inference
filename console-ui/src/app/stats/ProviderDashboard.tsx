"use client";

import { useEffect, useMemo, useState } from "react";
import {
  FilterX,
  Search,
  Server,
  ShieldAlert,
  ShieldCheck,
} from "lucide-react";
import { ProviderNodeDetail } from "./ProviderNodeDetail";
import {
  compactProviderId,
  compareProviders,
  isProviderRoutable,
  matchesTrustFilter,
  providerRouteState,
  shortProviderModel,
  summarizeProviderFleet,
  type ProviderRouteState,
  type ProviderSortKey,
  type ProviderStats,
  type ProviderStatusFilter,
  type ProviderTrustFilter,
} from "./provider-fleet";

function formatCompact(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return value.toLocaleString();
}

const SERVING_STYLE = {
  label: "Serving",
  rail: "bg-accent-brand",
  badge: "bg-accent-brand/10 text-accent-brand",
};
const READY_STYLE = {
  label: "Ready",
  rail: "bg-accent-green",
  badge: "bg-accent-green/10 text-accent-green",
};
const ATTENTION_STYLE = {
  label: "Attention",
  rail: "bg-accent-amber",
  badge: "bg-accent-amber-dim text-accent-amber",
};

function stateStyle(state: ProviderRouteState) {
  if (state === "serving") return SERVING_STYLE;
  if (state === "ready") return READY_STYLE;
  return ATTENTION_STYLE;
}

function FleetMetric({ label, value, detail, tone }: { label: string; value: number; detail: string; tone?: "green" | "amber" }) {
  let valueColor = "text-text-primary";
  if (tone === "green") valueColor = "text-accent-green";
  if (tone === "amber") valueColor = "text-accent-amber";
  return (
    <div className="border-l border-border-dim pl-3 first:border-l-0 first:pl-0">
      <p className={`font-mono text-xl font-bold tabular-nums ${valueColor}`}>{value.toLocaleString()}</p>
      <p className="mt-0.5 text-xs font-semibold text-text-secondary">{label}</p>
      <p className="mt-1 text-[9px] leading-3 text-text-tertiary">{detail}</p>
    </div>
  );
}

function StateLegend({ state, count }: { state: ProviderRouteState; count: number }) {
  const style = stateStyle(state);
  return (
    <span className="inline-flex items-center gap-1.5 font-mono text-[10px] text-text-tertiary">
      <span className={`h-1.5 w-1.5 rounded-full ${style.rail}`} />
      {style.label} {count}
    </span>
  );
}

function ProviderRow({ provider, selected, onSelect }: { provider: ProviderStats; selected: boolean; onSelect: () => void }) {
  const state = providerRouteState(provider);
  const style = stateStyle(state);
  const activeModel = provider.current_model || provider.models?.[0];
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      className={`group relative w-full overflow-hidden rounded-xl border py-3 pl-4 pr-3 text-left transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand ${selected ? "border-accent-brand/35 bg-accent-brand/5" : "border-border-dim bg-bg-secondary hover:border-border-subtle hover:bg-bg-hover"}`}
    >
      <span className={`absolute inset-y-0 left-0 w-1 ${style.rail}`} aria-hidden="true" />
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold text-text-primary">{provider.chip}</p>
          <p className="mt-0.5 truncate font-mono text-[10px] text-text-tertiary">
            {provider.machine_model || "Apple Silicon"} · {compactProviderId(provider.id)}
          </p>
        </div>
        <span className={`shrink-0 rounded-full px-2 py-0.5 font-mono text-[9px] uppercase tracking-wider ${style.badge}`}>
          {style.label}
        </span>
      </div>
      {activeModel && (
        <p className="mt-2 truncate text-[11px] font-medium text-text-secondary">
          {shortProviderModel(activeModel)}
        </p>
      )}
      <div className="mt-3 grid grid-cols-3 gap-2 border-t border-border-dim pt-2 font-mono text-[10px]">
        <div><p className="text-text-tertiary">Memory</p><p className="mt-0.5 text-text-primary">{provider.memory_gb} GB</p></div>
        <div><p className="text-text-tertiary">GPU</p><p className="mt-0.5 text-text-primary">{provider.gpu_cores} cores</p></div>
        <div><p className="text-text-tertiary">Tokens</p><p className="mt-0.5 text-text-primary">{formatCompact(provider.tokens_generated)}</p></div>
      </div>
      <div className="mt-2 flex items-center gap-1.5 text-[9px] text-text-tertiary">
        {provider.trust_level === "hardware" ? <ShieldCheck size={10} className="text-accent-green" /> : <ShieldAlert size={10} />}
        {provider.trust_level === "hardware" ? "Hardware-backed identity" : "Basic identity"}
      </div>
    </button>
  );
}

export function ProviderDashboard({ providers }: { providers: ProviderStats[] }) {
  const [selectedProviderId, setSelectedProviderId] = useState("");
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<ProviderStatusFilter>("all");
  const [trustFilter, setTrustFilter] = useState<ProviderTrustFilter>("all");
  const [modelFilter, setModelFilter] = useState("all");
  const [sortKey, setSortKey] = useState<ProviderSortKey>("readiness");
  const summary = useMemo(() => summarizeProviderFleet(providers), [providers]);
  const admitted = summary.ready + summary.serving;

  const modelOptions = useMemo(
    () => Array.from(new Set(providers.flatMap((provider) => provider.models ?? [])))
      .sort((a, b) => shortProviderModel(a).localeCompare(shortProviderModel(b))),
    [providers],
  );

  const filteredProviders = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return providers.filter((provider) => {
      const models = provider.models ?? [];
      const haystack = [provider.id, provider.chip, provider.machine_model, provider.current_model, ...models]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      const state = providerRouteState(provider);
      return (
        (normalizedQuery === "" || haystack.includes(normalizedQuery)) &&
        (statusFilter === "all" || state === statusFilter) &&
        matchesTrustFilter(provider, trustFilter) &&
        (modelFilter === "all" || models.includes(modelFilter))
      );
    }).sort((a, b) => compareProviders(a, b, sortKey));
  }, [modelFilter, providers, query, sortKey, statusFilter, trustFilter]);

  const selectedProvider =
    filteredProviders.find((provider) => provider.id === selectedProviderId) ??
    filteredProviders[0] ??
    null;

  useEffect(() => {
    if (selectedProvider && selectedProvider.id !== selectedProviderId) {
      setSelectedProviderId(selectedProvider.id);
    }
  }, [selectedProvider, selectedProviderId]);

  const hasFilters = query !== "" || statusFilter !== "all" || trustFilter !== "all" || modelFilter !== "all" || sortKey !== "readiness";
  function clearFilters() {
    setQuery("");
    setStatusFilter("all");
    setTrustFilter("all");
    setModelFilter("all");
    setSortKey("readiness");
    setSelectedProviderId("");
  }

  const readyPct = summary.visible > 0 ? ((summary.ready + summary.serving) / summary.visible) * 100 : 0;
  const servingPct = summary.visible > 0 ? (summary.serving / summary.visible) * 100 : 0;

  return (
    <section className="overflow-hidden rounded-xl border border-border-dim bg-bg-white shadow-sm">
      <div className="p-5">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex items-start gap-3">
            <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-accent-brand text-white">
              <Server size={17} />
            </div>
            <div>
              <p className="font-mono text-[9px] uppercase tracking-[0.18em] text-accent-brand">Live provider directory</p>
              <h2 className="mt-1 text-base font-semibold text-text-primary">Provider fleet</h2>
              <p className="mt-1 max-w-lg text-xs leading-5 text-text-tertiary">
                See which machines can receive public requests, what they serve, and why any node is excluded.
              </p>
            </div>
          </div>
          <div className="inline-flex w-fit items-center gap-1.5 rounded-full border border-accent-green/25 bg-accent-green/10 px-2.5 py-1 font-mono text-[10px] text-accent-green">
            <span className="h-1.5 w-1.5 rounded-full bg-accent-green" />
            Updating every 15s
          </div>
        </div>

        <div className="mt-5 grid grid-cols-2 gap-x-4 gap-y-4 sm:grid-cols-4">
          <FleetMetric label="Visible nodes" value={summary.visible} detail="reporting to the network" />
          <FleetMetric label="Can take work" value={admitted} detail="passed every route check" tone="green" />
          <FleetMetric label="Serving now" value={summary.serving} detail="currently processing traffic" />
          <FleetMetric label="Needs attention" value={summary.attention} detail="excluded from public routing" tone={summary.attention > 0 ? "amber" : undefined} />
        </div>

        <div className="mt-4">
          <div className="flex h-2 overflow-hidden rounded-full bg-bg-elevated" aria-label={`${Math.round(readyPct)}% of visible nodes can take work`}>
            <span className="bg-accent-brand" style={{ width: `${servingPct}%` }} />
            <span className="bg-accent-green/75" style={{ width: `${Math.max(0, readyPct - servingPct)}%` }} />
            <span className="flex-1 bg-accent-amber/45" />
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1">
            <StateLegend state="serving" count={summary.serving} />
            <StateLegend state="ready" count={summary.ready} />
            <StateLegend state="attention" count={summary.attention} />
            <span className="ml-auto font-mono text-[10px] font-semibold text-accent-green">{Math.round(readyPct)}% admitted</span>
          </div>
        </div>
      </div>

      <div className="border-y border-border-dim bg-bg-secondary/70 px-5 py-4">
        <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_190px]">
          <label className="relative block">
            <Search size={14} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary" />
            <input
              value={query}
              onChange={(event) => {
                setQuery(event.target.value);
                setSelectedProviderId("");
              }}
              placeholder="Find a chip, model, or node ID"
              aria-label="Search provider fleet"
              className="h-10 w-full rounded-lg border border-border-dim bg-bg-white pl-9 pr-3 text-sm text-text-primary outline-none transition-colors placeholder:text-text-tertiary focus:border-accent-brand/45"
            />
          </label>
          <select value={modelFilter} onChange={(event) => {
            setModelFilter(event.target.value);
            setSelectedProviderId("");
          }} aria-label="Filter by model" className="h-10 rounded-lg border border-border-dim bg-bg-white px-3 text-xs font-medium text-text-primary outline-none focus:border-accent-brand/45">
            <option value="all">Every model</option>
            {modelOptions.map((model) => <option key={model} value={model}>{shortProviderModel(model)}</option>)}
          </select>
        </div>
        <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-[1fr_150px_170px_auto]">
          <select value={statusFilter} onChange={(event) => {
            setStatusFilter(event.target.value as ProviderStatusFilter);
            setSelectedProviderId("");
          }} aria-label="Filter by routing state" className="h-9 rounded-lg border border-border-dim bg-bg-white px-3 text-xs text-text-secondary outline-none focus:border-accent-brand/45">
            <option value="all">Every routing state</option>
            <option value="ready">Ready and idle</option>
            <option value="serving">Serving now</option>
            <option value="attention">Needs attention</option>
          </select>
          <select value={trustFilter} onChange={(event) => {
            setTrustFilter(event.target.value as ProviderTrustFilter);
            setSelectedProviderId("");
          }} aria-label="Filter by trust" className="h-9 rounded-lg border border-border-dim bg-bg-white px-3 text-xs text-text-secondary outline-none focus:border-accent-brand/45">
            <option value="all">All trust</option>
            <option value="hardware">Hardware trust</option>
            <option value="basic">Basic identity</option>
          </select>
          <select value={sortKey} onChange={(event) => setSortKey(event.target.value as ProviderSortKey)} aria-label="Sort providers" className="h-9 rounded-lg border border-border-dim bg-bg-white px-3 text-xs text-text-secondary outline-none focus:border-accent-brand/45">
            <option value="readiness">Readiness first</option>
            <option value="hardware">Largest hardware</option>
            <option value="requests">Most requests</option>
            <option value="tokens">Most tokens</option>
            <option value="chip">Chip name</option>
          </select>
          <button type="button" onClick={clearFilters} disabled={!hasFilters} className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg px-3 text-xs text-text-tertiary transition-colors hover:bg-bg-hover hover:text-text-primary disabled:cursor-default disabled:opacity-35">
            <FilterX size={13} /> Reset
          </button>
        </div>
      </div>

      <div className="p-5">
        <div className="mb-3 flex items-center justify-between gap-3">
          <p className="text-xs font-semibold text-text-secondary">Fleet inspection</p>
          <p className="font-mono text-[10px] text-text-tertiary">Showing {filteredProviders.length} of {providers.length}</p>
        </div>
        {filteredProviders.length === 0 ? (
          <div className="rounded-xl border border-dashed border-border-subtle bg-bg-secondary p-8 text-center">
            <Search size={18} className="mx-auto text-text-tertiary" />
            <p className="mt-3 text-sm font-medium text-text-primary">No matching nodes</p>
            <p className="mt-1 text-xs text-text-tertiary">Change the search or reset the filters to see the fleet.</p>
            <button type="button" onClick={clearFilters} className="mt-4 text-xs font-medium text-accent-brand hover:underline">Reset filters</button>
          </div>
        ) : (
          <div className="grid items-start gap-3 md:grid-cols-[minmax(235px,0.78fr)_minmax(0,1.22fr)]">
            <div className="space-y-2 md:max-h-[760px] md:overflow-y-auto md:pr-1">
              {filteredProviders.map((provider) => (
                <ProviderRow key={provider.id} provider={provider} selected={provider.id === selectedProvider?.id} onSelect={() => setSelectedProviderId(provider.id)} />
              ))}
            </div>
            <div className="md:sticky md:top-4">
              <ProviderNodeDetail provider={selectedProvider} />
            </div>
          </div>
        )}
      </div>
    </section>
  );
}

export { isProviderRoutable };
