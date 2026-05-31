// Parsers that turn raw form-input strings into the sparse PATCH/create values
// the API expects. Each returns:
//   - a value   → set this limit
//   - null      → explicitly clear the limit (only on edit, when input is empty)
//   - undefined → leave unchanged / omit
// On create, `clear` is false so an empty input simply omits the field.

export function numOrClear(raw: string, clear: boolean): number | null | undefined {
  const v = raw.trim();
  if (!v) return clear ? null : undefined;
  const n = Number(v);
  // Spend cap: 0 is a valid zero-dollar cap (the key can't spend), so accept
  // any non-negative finite value. Empty string clears (on edit).
  return Number.isFinite(n) && n >= 0 ? n : undefined;
}

export function intOrClear(raw: string, clear: boolean): number | null | undefined {
  const v = raw.trim();
  if (!v) return clear ? null : undefined;
  const n = Math.floor(Number(v));
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

export function expiryOrClear(raw: string, clear: boolean): string | null | undefined {
  const v = raw.trim();
  if (!v) return clear ? null : undefined;
  const d = new Date(`${v}T23:59:59Z`);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

export function modelsOrClear(list: string[], clear: boolean): string[] | null | undefined {
  if (list.length > 0) return list;
  return clear ? null : undefined;
}
