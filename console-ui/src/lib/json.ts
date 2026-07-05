// Defensive coercion helpers for untyped JSON (coordinator responses, etc.).
//
// Consolidates the asRecord/asString/asNumber/asStringArray/compactObject set
// that was copy-pasted across lib/stats-model-filter.ts, app/api/models/route.ts
// and inlined in stats. One implementation, one place to fix a bug.

/** Narrow an unknown to a plain object, or {} for arrays/primitives/null. */
export function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** A trimmed non-empty string, or undefined. */
export function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** A finite number, or undefined. */
export function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/** A boolean, or undefined (so callers can distinguish "absent" from false). */
export function asBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

/** A non-empty array of non-empty strings, or undefined. */
export function asStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const strings = value.filter(
    (item): item is string => typeof item === "string" && item.length > 0,
  );
  return strings.length > 0 ? strings : undefined;
}

/** Drop keys whose value is `undefined` (keeps null/0/"" intact). */
export function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined),
  ) as T;
}
