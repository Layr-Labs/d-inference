import { Search, X } from "lucide-react";
import { MODEL_FILTERS, type ModelFilter, type ModelSort } from "./catalog";

interface Props {
  query: string;
  filter: ModelFilter;
  sort: ModelSort;
  onQueryChange: (query: string) => void;
  onFilterChange: (filter: ModelFilter) => void;
  onSortChange: (sort: ModelSort) => void;
}

export function CatalogToolbar({ query, filter, sort, onQueryChange, onFilterChange, onSortChange }: Props) {
  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 sm:flex-row">
        <div className="relative flex-1">
          <Search size={18} aria-hidden="true" className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-text-secondary" />
          <input
            type="search"
            value={query}
            onChange={(event) => onQueryChange(event.target.value)}
            placeholder="Search models, families, or capabilities"
            aria-label="Search models"
            className="focus-ring h-12 w-full rounded-xl border border-border-dim bg-bg-white pr-12 pl-11 text-sm text-text-primary placeholder:text-text-tertiary [&::-webkit-search-cancel-button]:appearance-none"
          />
          {query && (
            <button onClick={() => onQueryChange("")} aria-label="Clear search" className="absolute top-1/2 right-2 flex size-9 -translate-y-1/2 items-center justify-center rounded-lg text-text-secondary hover:bg-bg-secondary">
              <X size={16} />
            </button>
          )}
        </div>
        <label className="flex h-12 items-center gap-2 rounded-xl border border-border-dim bg-bg-white px-4 text-sm">
          <span className="shrink-0 text-text-secondary">Sort by</span>
          <select value={sort} onChange={(event) => onSortChange(event.target.value as ModelSort)} className="focus-ring min-w-0 flex-1 bg-transparent py-2 pr-1 text-text-primary" aria-label="Sort models">
            <option value="name">Name</option>
            <option value="context">Largest context</option>
            <option value="input">Lowest input price</option>
            <option value="output">Lowest output price</option>
          </select>
        </label>
      </div>
      <div className="flex flex-wrap gap-1" role="group" aria-label="Filter by capability">
        {MODEL_FILTERS.map((item) => (
          <button
            key={item.value}
            aria-pressed={filter === item.value}
            onClick={() => onFilterChange(item.value)}
            className={`focus-ring min-h-10 rounded-lg px-3.5 text-sm transition-colors ${filter === item.value ? "bg-coral-light font-medium text-coral" : "text-text-secondary hover:bg-bg-secondary hover:text-text-primary"}`}
          >
            {item.label}
          </button>
        ))}
      </div>
    </div>
  );
}
