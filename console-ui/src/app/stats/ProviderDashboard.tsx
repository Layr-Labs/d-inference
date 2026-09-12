"use client";

import { useMemo, useState } from "react";
import { ArrowLeft, ArrowRight } from "lucide-react";
import { isProviderRoutable, shortProviderModel, summarizeProviderFleet, type ProviderStats } from "./provider-fleet";
import { ProviderFilters } from "./providers/ProviderFilters";
import { ProviderTable } from "./providers/ProviderTable";
import { DEFAULT_DIRECTORY_FILTERS, filterProviderDirectory, providerDirectoryPage, providerModels, type ProviderDirectoryFilters } from "./providers/provider-directory";

function FleetMetric({ label, value }: { label: string; value: number }) {
  return <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5"><p className="text-xl font-semibold tabular-nums tracking-tight text-text-primary">{value.toLocaleString()}</p><p className="text-xs text-text-tertiary">{label}</p></div>;
}

export function ProviderDashboard({ providers }: { providers: ProviderStats[] }) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [filters, setFilters] = useState(DEFAULT_DIRECTORY_FILTERS);
  const [filtersExpanded, setFiltersExpanded] = useState(false);
  const [requestedPage, setRequestedPage] = useState(1);
  const summary = useMemo(() => summarizeProviderFleet(providers), [providers]);
  const modelOptions = useMemo(() => [...new Set(providers.flatMap(providerModels))].sort((a, b) => shortProviderModel(a).localeCompare(shortProviderModel(b))), [providers]);
  const filtered = useMemo(() => filterProviderDirectory(providers, filters), [providers, filters]);
  const pagination = providerDirectoryPage(filtered, requestedPage);
  const hasFilters = Object.keys(DEFAULT_DIRECTORY_FILTERS).some((key) => filters[key as keyof ProviderDirectoryFilters] !== DEFAULT_DIRECTORY_FILTERS[key as keyof ProviderDirectoryFilters]);

  function updateFilters(change: Partial<ProviderDirectoryFilters>) {
    setFilters((current) => ({ ...current, ...change }));
    setRequestedPage(1);
    setSelectedId(null);
  }
  function resetFilters() {
    setFilters(DEFAULT_DIRECTORY_FILTERS);
    setRequestedPage(1);
    setSelectedId(null);
  }
  function changePage(page: number) {
    setRequestedPage(page);
    setSelectedId(null);
  }

  return (
    <section aria-labelledby="providers-heading" className="min-w-0">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <h2 id="providers-heading" className="text-xl font-semibold tracking-tight text-text-primary">Provider directory</h2>
        <span className="shrink-0 pt-1 text-xs text-text-tertiary">Updates every 30 seconds</span>
      </div>
      <div className="mt-4 grid grid-cols-2 gap-x-5 gap-y-3 border-b border-border-dim pb-4 sm:grid-cols-4">
        <FleetMetric label="Visible nodes" value={summary.visible} />
        <FleetMetric label="Hardware verified" value={summary.hardware} />
        <FleetMetric label="Serving now" value={summary.serving} />
        <FleetMetric label="Routing unreported" value={summary.unreported} />
      </div>
      <ProviderFilters filters={filters} modelOptions={modelOptions} expanded={filtersExpanded} hasFilters={hasFilters} onChange={updateFilters} onToggle={() => setFiltersExpanded((current) => !current)} onReset={resetFilters} />
      <div className="mb-3 mt-3 flex min-h-8 flex-wrap items-center justify-between gap-3">
        <p role="status" className="text-xs tabular-nums text-text-tertiary">{filtered.length > 0 ? `${pagination.start + 1}–${pagination.start + pagination.providers.length} of ${filtered.length.toLocaleString()} nodes` : "0 matching nodes"}{hasFilters && ` · ${providers.length.toLocaleString()} total`}</p>
        {pagination.pageCount > 1 && <nav aria-label="Provider directory pagination" className="flex items-center gap-3">
          <button type="button" onClick={() => changePage(pagination.page - 1)} disabled={pagination.page === 1} aria-label="Previous provider page" className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border-dim text-text-secondary transition-colors hover:bg-bg-hover disabled:opacity-35 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand"><ArrowLeft size={15} /></button>
          <span className="text-xs tabular-nums text-text-secondary">{pagination.page} / {pagination.pageCount}</span>
          <button type="button" onClick={() => changePage(pagination.page + 1)} disabled={pagination.page === pagination.pageCount} aria-label="Next provider page" className="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-border-dim text-text-secondary transition-colors hover:bg-bg-hover disabled:opacity-35 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand"><ArrowRight size={15} /></button>
        </nav>}
      </div>
      {filtered.length > 0 ? <ProviderTable providers={pagination.providers} selectedId={selectedId} onSelect={(id) => setSelectedId((current) => current === id ? null : id)} /> : (
        <div className="border-y border-border-dim py-16 text-center"><p className="text-sm font-medium text-text-primary">{hasFilters ? "No nodes match these filters" : "No provider nodes reported"}</p><p className="mt-2 text-sm text-text-tertiary">{hasFilters ? "Try a different search or reset the filters." : "Connected machines will appear here in the next snapshot."}</p>{hasFilters && <button type="button" onClick={resetFilters} className="mt-4 text-sm font-medium text-accent-brand">Reset filters</button>}</div>
      )}
      <p className="mt-5 text-xs leading-5 text-text-tertiary">Public verification fields do not include every routing check. Per-node routing eligibility is unknown unless explicitly reported; model capacity is reported separately.</p>
    </section>
  );
}

export { isProviderRoutable };
