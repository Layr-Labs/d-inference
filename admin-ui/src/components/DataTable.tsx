import type { ReactNode } from "react";

export interface Column<T> {
  key: string;
  header: string;
  render?: (row: T) => ReactNode;
  mono?: boolean;
  align?: "left" | "right";
}

// Generic, presentational, server-rendered table. No client JS.
export function DataTable<T>({
  columns,
  rows,
  empty = "No rows.",
}: {
  columns: Column<T>[];
  rows: T[];
  empty?: string;
}) {
  if (rows.length === 0) {
    return <div className="text-[var(--text-faint)] py-8 text-center">{empty}</div>;
  }
  return (
    <div className="overflow-x-auto rounded-lg border border-[var(--border)]">
      <table className="w-full border-collapse text-left">
        <thead>
          <tr className="bg-[var(--bg-elevated)]">
            {columns.map((c) => (
              <th
                key={c.key}
                className={`px-3 py-2 text-xs font-medium uppercase tracking-wide text-[var(--text-dim)] ${
                  c.align === "right" ? "text-right" : ""
                }`}
              >
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
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
  );
}
