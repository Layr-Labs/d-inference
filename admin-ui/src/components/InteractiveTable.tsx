"use client";

import { useMemo, useState, type ReactNode } from "react";

export interface ICol<T> {
  key: string;
  header: string;
  render?: (row: T) => ReactNode;
  mono?: boolean;
  align?: "left" | "right";
  // If set, the column header becomes click-to-sort using this value.
  sortValue?: (row: T) => string | number;
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

  const filtered = useMemo(() => {
    const needle = q.trim().toLowerCase();
    let r = needle
      ? rows.filter((row) => searchText(row).toLowerCase().includes(needle))
      : rows.slice();
    if (sortKey) {
      const col = columns.find((c) => c.key === sortKey);
      if (col?.sortValue) {
        const sv = col.sortValue;
        r = [...r].sort((a, b) => {
          // Normalize Dates to epoch millis so date columns sort chronologically
          // (TIMESTAMPTZ values come back as JS Dates; String(date) would sort by
          // weekday/month name, not by time).
          const norm = (v: unknown) => (v instanceof Date ? v.getTime() : v);
          const av = norm(sv(a));
          const bv = norm(sv(b));
          const cmp =
            typeof av === "number" && typeof bv === "number"
              ? av - bv
              : String(av).localeCompare(String(bv));
          return sortDir === "asc" ? cmp : -cmp;
        });
      }
    }
    return r;
  }, [q, rows, searchText, sortKey, sortDir, columns]);

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
      setTimeout(() => setCopied(null), 1500);
    } catch {
      setCopied("Copy failed");
      setTimeout(() => setCopied(null), 1500);
    }
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

      {filtered.length === 0 ? (
        <div className="py-8 text-center text-[var(--text-faint)]">{empty}</div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-[var(--border)]">
          <table className="w-full border-collapse text-left">
            <thead>
              <tr className="bg-[var(--bg-elevated)]">
                {columns.map((c) => {
                  const active = sortKey === c.key;
                  return (
                    <th
                      key={c.key}
                      onClick={() => toggleSort(c)}
                      className={`px-3 py-2 text-xs font-medium uppercase tracking-wide text-[var(--text-dim)] ${
                        c.align === "right" ? "text-right" : ""
                      } ${c.sortValue ? "cursor-pointer select-none hover:text-[var(--text)]" : ""}`}
                    >
                      {c.header}
                      {c.sortValue && active ? (sortDir === "asc" ? " ▲" : " ▼") : ""}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {filtered.map((row, i) => (
                <tr
                  key={i}
                  className="border-t border-[var(--border)] hover:bg-[var(--bg-hover)]"
                >
                  {columns.map((c) => (
                    <td
                      key={c.key}
                      className={`px-3 py-2 align-top ${c.mono ? "mono" : ""} ${
                        c.align === "right" ? "text-right tabular-nums" : ""
                      }`}
                    >
                      {c.render
                        ? c.render(row)
                        : (((row as Record<string, unknown>)[c.key] as ReactNode) ?? "—")}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
