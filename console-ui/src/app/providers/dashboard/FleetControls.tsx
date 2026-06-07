// Controls header for the machine grid: a section title + count, a sort
// selector, and a grid/rows density toggle. Presentational — MachineGrid owns
// the state.

import { LayoutGrid, Rows3 } from "lucide-react";

export type SortMode = "attention" | "earnings" | "name";
export type Density = "grid" | "rows";

const SORTS: { id: SortMode; label: string }[] = [
  { id: "attention", label: "Attention" },
  { id: "earnings", label: "Earnings" },
  { id: "name", label: "Name" },
];

export function FleetControls({
  count,
  sort,
  onSort,
  density,
  onDensity,
}: {
  count: number;
  sort: SortMode;
  onSort: (s: SortMode) => void;
  density: Density;
  onDensity: (d: Density) => void;
}) {
  return (
    <div className="flex items-center justify-between gap-3 flex-wrap">
      <h3 className="text-sm font-semibold text-text-primary">
        Machines <span className="font-mono text-text-tertiary">{count}</span>
      </h3>
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-1">
          <span className="text-[11px] text-text-tertiary hidden sm:inline">Sort</span>
          {SORTS.map((s) => (
            <button
              key={s.id}
              type="button"
              aria-pressed={sort === s.id}
              onClick={() => onSort(s.id)}
              className={`focus-ring px-2.5 py-1 rounded-md text-xs font-medium transition-colors ${
                sort === s.id
                  ? "bg-accent-brand/10 text-accent-brand"
                  : "text-text-tertiary hover:text-text-secondary hover:bg-bg-hover"
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>
        <div className="flex items-center rounded-md border border-border-dim/60 overflow-hidden">
          <button
            type="button"
            onClick={() => onDensity("grid")}
            aria-label="Grid view"
            aria-pressed={density === "grid"}
            className={`focus-ring p-1.5 ${density === "grid" ? "bg-accent-brand/10 text-accent-brand" : "text-text-tertiary hover:bg-bg-hover"}`}
          >
            <LayoutGrid size={14} />
          </button>
          <button
            type="button"
            onClick={() => onDensity("rows")}
            aria-label="Rows view"
            aria-pressed={density === "rows"}
            className={`focus-ring p-1.5 ${density === "rows" ? "bg-accent-brand/10 text-accent-brand" : "text-text-tertiary hover:bg-bg-hover"}`}
          >
            <Rows3 size={14} />
          </button>
        </div>
      </div>
    </div>
  );
}
