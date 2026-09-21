import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { DataTable, type Column } from "./DataTable";

type Row = { name: string; count: number; absent?: string };
const columns: Column<Row>[] = [
  { key: "name", header: "Name", render: row => createElement("strong", null, row.name) },
  { key: "count", header: "Count", align: "right", mono: true },
  { key: "absent", header: "Missing" },
];

describe("shared table presentation", () => {
  it("preserves custom cells, zero counts, missing values and alignment", () => {
    const html = renderToStaticMarkup(createElement(DataTable<Row>, {
      columns, rows: [{ name: "<private>", count: 0 }],
    }));
    expect(html).toContain("<strong>&lt;private&gt;</strong>");
    expect(html).toContain("text-right tabular-nums");
    expect(html).toMatch(/<td[^>]*>0<\/td>/);
    expect(html).toMatch(/<td[^>]*>—<\/td>/);
  });
  it("renders empty state without a table", () => {
    const html = renderToStaticMarkup(createElement(DataTable<Row>, { columns, rows: [], empty: "No machines." }));
    expect(html).toContain("No machines.");
    expect(html).not.toContain("<table");
  });
});
