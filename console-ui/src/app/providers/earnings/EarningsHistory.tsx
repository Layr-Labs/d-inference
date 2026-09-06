"use client";

// Recent-activity shell. Default view is one summary row per model; clicking
// a model drills into its log, paginated at PAGE_SIZE rows. All client-side
// over rows already filtered upstream (ActivityFilterBar owns the model filter).

import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, ChevronLeft, ChevronRight } from "lucide-react";
import type { Earning } from "./types";
import { perModelSummary } from "./aggregate";
import { modelLabel } from "./format";
import { EarningsRow } from "./EarningsRow";
import { ModelSummaryList } from "./ModelSummaryList";

export const PAGE_SIZE = 10;

export function EarningsHistory({
  earnings,
  totalJobs,
  recentCount,
  filteredOut = false,
}: {
  /** Rows already narrowed by the global model filter. */
  earnings: Earning[];
  totalJobs: number;
  recentCount: number;
  /** True when there ARE earnings, just none matching the current filters. */
  filteredOut?: boolean;
}) {
  const [selectedModel, setSelectedModel] = useState<string | null>(null);
  const [page, setPage] = useState(1);

  const summaries = useMemo(() => perModelSummary(earnings), [earnings]);
  const allModelIds = summaries.map((s) => s.model);

  // A global-filter change can remove the drilled-into model from the rows.
  // Fall back to the summary list instead of a stale, misleading empty log.
  useEffect(() => {
    if (selectedModel && !summaries.some((s) => s.model === selectedModel)) {
      setSelectedModel(null);
      setPage(1);
    }
  }, [selectedModel, summaries]);

  const modelRows = useMemo(
    () =>
      selectedModel ? earnings.filter((e) => e.model === selectedModel) : [],
    [earnings, selectedModel],
  );
  const pageCount = Math.max(1, Math.ceil(modelRows.length / PAGE_SIZE));
  const safePage = Math.min(page, pageCount);
  const pageRows = modelRows.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE);

  const openModel = (model: string) => {
    setSelectedModel(model);
    setPage(1);
  };

  return (
    <div>
      {selectedModel && (
        <div className="flex flex-wrap items-center gap-3 mb-3">
          <button
            onClick={() => setSelectedModel(null)}
            className="flex items-center gap-1 text-sm text-text-secondary hover:text-text-primary transition-colors"
          >
            <ArrowLeft size={14} />
            All models
          </button>
          <h3 className="text-sm font-semibold font-mono text-text-primary truncate max-w-[18rem]">
            {modelLabel(selectedModel, allModelIds)}
          </h3>
        </div>
      )}
      {totalJobs > recentCount && (
        <p className="text-xs text-text-tertiary mb-3">
          Showing the latest {recentCount} of{" "}
          {totalJobs.toLocaleString("en-US")} payouts.
        </p>
      )}
      <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
        {selectedModel && <ModelLog rows={pageRows} allModelIds={allModelIds} />}
        {!selectedModel && summaries.length > 0 && (
          <ModelSummaryList summaries={summaries} onSelect={openModel} />
        )}
        {!selectedModel && summaries.length === 0 && (
          <EmptyCopy filtered={filteredOut} />
        )}
      </div>
      {selectedModel && modelRows.length > PAGE_SIZE && (
        <Pager
          page={safePage}
          pageCount={pageCount}
          onPage={setPage}
          total={modelRows.length}
        />
      )}
    </div>
  );
}

function ModelLog({
  rows,
  allModelIds,
}: {
  rows: Earning[];
  allModelIds: string[];
}) {
  if (rows.length === 0) return <EmptyCopy filtered />;
  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead>
          <tr className="border-b border-border-dim">
            <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Model</th>
            <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Earned</th>
            <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Tokens</th>
            <th className="text-left text-xs text-text-tertiary font-medium px-4 py-3">Time</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((e) => (
            <EarningsRow
              key={e.id}
              earning={e}
              label={modelLabel(e.model, allModelIds)}
            />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Pager({
  page,
  pageCount,
  onPage,
  total,
}: {
  page: number;
  pageCount: number;
  onPage: (p: number) => void;
  total: number;
}) {
  const pagerBtn =
    "flex items-center gap-1 px-3 py-1.5 rounded-lg bg-bg-secondary text-xs text-text-secondary hover:bg-bg-hover disabled:opacity-50 disabled:cursor-not-allowed transition-colors";
  return (
    <div className="flex items-center justify-between mt-3">
      <button
        onClick={() => onPage(page - 1)}
        disabled={page <= 1}
        className={pagerBtn}
      >
        <ChevronLeft size={14} />
        Previous
      </button>
      <p className="text-xs text-text-tertiary">
        Page {page} of {pageCount} · {total.toLocaleString("en-US")} payouts
      </p>
      <button
        onClick={() => onPage(page + 1)}
        disabled={page >= pageCount}
        className={pagerBtn}
      >
        Next
        <ChevronRight size={14} />
      </button>
    </div>
  );
}

function EmptyCopy({ filtered }: { filtered: boolean }) {
  return (
    <div className="text-center py-12 text-text-tertiary">
      <p className="text-sm">
        {filtered
          ? "No earnings match the current filters"
          : "No earnings activity yet"}
      </p>
      <p className="text-xs mt-1">
        {filtered
          ? "Try selecting a different model."
          : "Earnings appear here when your provider serves inference requests"}
      </p>
    </div>
  );
}
