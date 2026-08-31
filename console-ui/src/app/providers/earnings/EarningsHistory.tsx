"use client";

// Recent-activity shell. Default view is one summary row per model; clicking
// a model drills into its log, paginated 25 rows per page. All client-side
// over the rows the API already returned.

import { useMemo, useState } from "react";
import { ArrowLeft, ChevronLeft, ChevronRight } from "lucide-react";
import type { Earning } from "./types";
import {
  filterEarnings,
  perModelSummary,
  truncationNote,
} from "./aggregate";
import { modelLabel } from "./format";
import { EarningsRow } from "./EarningsRow";
import { ModelSummaryList } from "./ModelSummaryList";

export const PAGE_SIZE = 10;

const RANGES = [
  { label: "Last 7 days", days: 7 },
  { label: "Last 30 days", days: 30 },
  { label: "All time", days: 0 },
];

export function EarningsHistory({
  earnings,
  totalJobs,
  recentCount,
}: {
  earnings: Earning[];
  totalJobs: number;
  recentCount: number;
}) {
  const [selectedModel, setSelectedModel] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [days, setDays] = useState(0);
  // Snapshot the clock outside render (react-hooks/purity); refreshed whenever
  // the look-back window changes, which is when it matters.
  const [now, setNow] = useState(() => Date.now());

  const inRange = useMemo(
    () => filterEarnings(earnings, { model: "", days }, now),
    [earnings, days, now],
  );
  const summaries = useMemo(() => perModelSummary(inRange), [inRange]);
  const allModelIds = useMemo(() => summaries.map((s) => s.model), [summaries]);

  const modelRows = useMemo(
    () =>
      selectedModel ? inRange.filter((e) => e.model === selectedModel) : [],
    [inRange, selectedModel],
  );
  const pageCount = Math.max(1, Math.ceil(modelRows.length / PAGE_SIZE));
  const safePage = Math.min(page, pageCount);
  const pageRows = modelRows.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE);

  const truncated = truncationNote(totalJobs, recentCount);

  const openModel = (model: string) => {
    setSelectedModel(model);
    setPage(1);
  };

  return (
    <div>
      <div className="flex flex-wrap items-center gap-3 mb-3">
        {selectedModel ? (
          <>
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
          </>
        ) : (
          <h3 className="text-sm font-semibold text-text-primary">
            Recent activity
          </h3>
        )}
        <select
          aria-label="Filter by time range"
          value={days}
          onChange={(e) => {
            setNow(Date.now());
            setDays(Number(e.target.value));
            setPage(1);
          }}
          className="ml-auto text-xs rounded-lg border border-border-default bg-bg-secondary text-text-secondary px-3 py-1.5 focus:outline-none focus:ring-1 focus:ring-accent-brand"
        >
          {RANGES.map((r) => (
            <option key={r.days} value={r.days}>
              {r.label}
            </option>
          ))}
        </select>
      </div>
      {truncated && (
        <p className="text-xs text-text-tertiary mb-3">
          Showing the latest {truncated.shown} of{" "}
          {truncated.total.toLocaleString("en-US")} payouts.
        </p>
      )}
      <div className="rounded-xl bg-bg-secondary shadow-sm overflow-hidden">
        {selectedModel && <ModelLog rows={pageRows} allModelIds={allModelIds} />}
        {!selectedModel && summaries.length > 0 && (
          <ModelSummaryList summaries={summaries} onSelect={openModel} />
        )}
        {!selectedModel && summaries.length === 0 && (
          <EmptyCopy filtered={earnings.length > 0} />
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
          ? "Try widening the time range."
          : "Earnings appear here when your provider serves inference requests"}
      </p>
    </div>
  );
}
