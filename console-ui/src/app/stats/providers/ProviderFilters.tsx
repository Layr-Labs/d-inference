import { Search, SlidersHorizontal } from "lucide-react";
import { shortProviderModel, type ProviderSortKey, type ProviderStatusFilter, type ProviderTrustFilter } from "../provider-fleet";
import type { ProviderDirectoryFilters } from "./provider-directory";

const SELECT_STYLE = "h-10 min-w-0 rounded-lg border border-border-dim bg-bg-white px-3 text-sm text-text-secondary outline-none focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/10";

export function ProviderFilters({ filters, modelOptions, expanded, hasFilters, onChange, onToggle, onReset }: {
  filters: ProviderDirectoryFilters;
  modelOptions: string[];
  expanded: boolean;
  hasFilters: boolean;
  onChange: (change: Partial<ProviderDirectoryFilters>) => void;
  onToggle: () => void;
  onReset: () => void;
}) {
  return (
    <div className="mt-4">
      <div className="flex flex-wrap gap-3">
        <label className="relative block min-w-48 flex-1 sm:max-w-sm">
          <Search size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary" />
          <input type="search" value={filters.query} onChange={(event) => onChange({ query: event.target.value })} placeholder="Search chip, model, or node ID" aria-label="Search provider fleet" className="h-11 w-full rounded-xl border border-border-dim bg-bg-white pl-10 pr-3 text-sm text-text-primary outline-none placeholder:text-text-tertiary focus:border-accent-brand focus:ring-2 focus:ring-accent-brand/10" />
        </label>
        <button type="button" onClick={onToggle} aria-expanded={expanded} aria-controls="provider-filters" className={`inline-flex h-11 items-center gap-2 rounded-xl border border-border-dim px-3.5 text-sm font-medium transition-colors hover:bg-bg-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand ${expanded ? "bg-bg-secondary text-text-primary" : "bg-bg-white text-text-secondary"}`}><SlidersHorizontal size={15} />Filters</button>
        {hasFilters && <button type="button" onClick={onReset} className="h-11 px-2 text-sm text-accent-brand hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand">Reset filters</button>}
      </div>
      {expanded && (
        <div id="provider-filters" className="mt-3 grid gap-3 rounded-xl bg-bg-secondary p-4 sm:grid-cols-2 xl:grid-cols-4">
          <label className="grid gap-2 text-xs text-text-tertiary">Routing state<select value={filters.status} onChange={(event) => onChange({ status: event.target.value as ProviderStatusFilter })} aria-label="Filter by routing state" className={SELECT_STYLE}>
            <option value="all">Every routing state</option><option value="ready">Ready and idle</option><option value="serving">Serving now</option><option value="attention">Routing excluded</option><option value="unreported">Routing not reported</option>
          </select></label>
          <label className="grid gap-2 text-xs text-text-tertiary">Model<select value={filters.model} onChange={(event) => onChange({ model: event.target.value })} aria-label="Filter by model" className={SELECT_STYLE}>
            <option value="all">Every model</option>{modelOptions.map((model) => <option key={model} value={model}>{shortProviderModel(model)}</option>)}
          </select></label>
          <label className="grid gap-2 text-xs text-text-tertiary">Trust<select value={filters.trust} onChange={(event) => onChange({ trust: event.target.value as ProviderTrustFilter })} aria-label="Filter by trust" className={SELECT_STYLE}>
            <option value="all">All trust levels</option><option value="hardware">Hardware trust</option><option value="basic">Basic identity</option>
          </select></label>
          <label className="grid gap-2 text-xs text-text-tertiary">Sort by<select value={filters.sort} onChange={(event) => onChange({ sort: event.target.value as ProviderSortKey })} aria-label="Sort providers" className={SELECT_STYLE}>
            <option value="readiness">Readiness first</option><option value="hardware">Largest hardware</option><option value="requests">Most requests</option><option value="tokens">Most tokens</option><option value="chip">Chip name</option>
          </select></label>
        </div>
      )}
    </div>
  );
}
