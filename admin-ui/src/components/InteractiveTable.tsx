"use client";

import { useMemo, useState } from "react";
import { DataTable, type Column } from "./DataTable";
import { tableRows } from "@/lib/table-rows";

export interface ICol<T> extends Column<T> {
  // Dates from TIMESTAMPTZ retain chronological ordering.
  sortValue?: (row: T) => string | number | Date;
}

// Client-side filterable / sortable table with an optional "copy all" action.
// Used from client view components (which define columns + the accessor fns, so
// nothing crosses the server→client boundary except the plain `rows` data).
export function InteractiveTable<T>({
  rows,
  columns,
  searchText,
  searchPlaceholder = "Filter…",
  copyField,
  copyLabel = "Copy emails",
  empty = "No rows.",
}: {
  rows: T[];
  columns: ICol<T>[];
  searchText: (row: T) => string;
  searchPlaceholder?: string;
  copyField?: (row: T) => string | null | undefined;
  copyLabel?: string;
  empty?: string;
}) {
  const [q, setQ] = useState("");
  const [sortKey, setSortKey] = useState<string | null>(null);
  const [sortDir, setSortDir] = useState<"asc" | "desc">("asc");
  const [copied, setCopied] = useState<string | null>(null);

  const filtered = useMemo(() => tableRows(
    rows, searchText, q,
    sortKey ? columns.find((column) => column.key === sortKey)?.sortValue : undefined,
    sortDir,
  ), [q, rows, searchText, sortKey, sortDir, columns]);

  function toggleSort(col: ICol<T>) {
    if (!col.sortValue) return;
    if (sortKey === col.key) {
      setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    } else {
      setSortKey(col.key);
      setSortDir("asc");
    }
  }

  async function copyAll() {
    if (!copyField) return;
    const vals = Array.from(
      new Set(filtered.map(copyField).filter((v): v is string => !!v)),
    );
    try {
      await navigator.clipboard.writeText(vals.join("\n"));
      setCopied(`Copied ${vals.length}`);
    } catch {
      setCopied("Copy failed");
    }
    setTimeout(() => setCopied(null), 1500);
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={searchPlaceholder}
          className="w-64 rounded border border-[var(--border)] bg-[var(--bg-elevated)] px-2 py-1 text-sm outline-none focus:border-[var(--accent)]"
        />
        <span className="text-xs text-[var(--text-faint)] tabular-nums">
          {filtered.length} / {rows.length}
        </span>
        {copyField && (
          <button
            type="button"
            onClick={copyAll}
            className="ml-auto rounded border border-[var(--border)] px-2 py-1 text-sm text-[var(--text-dim)] hover:bg-[var(--bg-hover)] hover:text-[var(--text)]"
          >
            {copied ?? copyLabel}
          </button>
        )}
      </div>

      <DataTable
        rows={filtered}
        empty={empty}
        columns={columns.map((column) => ({
          ...column,
          header: <>{column.header}{column.sortValue && sortKey === column.key ? (sortDir === "asc" ? " ▲" : " ▼") : ""}</>,
          headerProps: {
            onClick: () => toggleSort(column),
            className: column.sortValue ? "cursor-pointer select-none hover:text-[var(--text)]" : "",
          },
        }))}
      />
    </div>
  );
}
