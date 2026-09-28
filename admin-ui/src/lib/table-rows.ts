/** Filter and sort a private copy; never reorder the server-provided rows. */
export function tableRows<T>(
  rows: T[],
  searchText: (row: T) => string,
  query: string,
  sortValue?: (row: T) => string | number | Date,
  direction: "asc" | "desc" = "asc",
): T[] {
  const needle = query.trim().toLowerCase();
  const visible = needle
    ? rows.filter((row) => searchText(row).toLowerCase().includes(needle))
    : rows.slice();
  if (!sortValue) return visible;
  const normalize = (value: string | number | Date) => value instanceof Date ? value.getTime() : value;
  return visible.sort((a, b) => {
    const left = normalize(sortValue(a));
    const right = normalize(sortValue(b));
    const comparison = typeof left === "number" && typeof right === "number"
      ? left - right
      : String(left).localeCompare(String(right));
    return direction === "asc" ? comparison : -comparison;
  });
}
