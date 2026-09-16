import { describe, expect, it } from "vitest";
import { tableRows } from "./table-rows";

const rows = [
  { name: "Zoe", value: 10, seen: new Date("2026-09-02") },
  { name: "Amy", value: 2, seen: new Date("2026-09-01") },
  { name: "AMY second", value: 2, seen: new Date("2026-09-03") },
];
const name = (row: typeof rows[number]) => row.name;

describe("table row projection", () => {
  it("filters without case or surrounding whitespace and retains source order", () => {
    expect(tableRows(rows, name, "  amy  ").map(name)).toEqual(["Amy", "AMY second"]);
    expect(tableRows(rows, name, "missing")).toEqual([]);
  });
  it("sorts numeric values numerically and preserves tie order", () => {
    expect(tableRows(rows, name, "", row => row.value).map(name)).toEqual(["Amy", "AMY second", "Zoe"]);
    expect(tableRows(rows, name, "", row => row.value, "desc").map(name)).toEqual(["Zoe", "Amy", "AMY second"]);
    expect(rows.map(name)).toEqual(["Zoe", "Amy", "AMY second"]);
  });
  it("sorts database Date objects chronologically", () => {
    expect(tableRows(rows, name, "", row => row.seen).map(name)).toEqual(["Amy", "Zoe", "AMY second"]);
  });
  it("returns a private copy even without a filter or sort", () => {
    const result = tableRows(rows, name, "");
    expect(result).toEqual(rows);
    expect(result).not.toBe(rows);
  });
});
