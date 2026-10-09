// Display names for a model's `required_provider_capabilities` — the provider
// hardware/runtime a model can only be served on. Mirrors the provider CLI's
// `ProviderCapabilityLabels` (provider-swift/.../ModelRequirementDisplay.swift);
// keep the two label tables in sync. Unknown values render as their raw id so
// a newer catalog still shows something truthful.

const CAPABILITY_LABELS = new Map<string, string>([
  ["apple_m5", "Apple M5"],
  ["mlx_nax", "NAX runtime"],
]);

export function providerCapabilityLabel(capability: string): string {
  return CAPABILITY_LABELS.get(capability) ?? capability;
}

/**
 * Labels in stable wire-id order, de-duplicated, blanks dropped. Empty when
 * the model has no provider requirement.
 */
export function providerCapabilityLabels(capabilities?: string[] | null): string[] {
  if (!Array.isArray(capabilities)) return [];
  const ids = new Set<string>();
  for (const value of capabilities) {
    if (typeof value === "string" && value.trim()) ids.add(value.trim());
  }
  return [...ids].sort().map(providerCapabilityLabel);
}

/**
 * Compact badge text for a model card, e.g. "Apple M5 only" or
 * "Apple M5 + NAX runtime only". Null when there is nothing to show.
 */
export function providerRequirementBadge(capabilities?: string[] | null): string | null {
  const labels = providerCapabilityLabels(capabilities);
  if (labels.length === 0) return null;
  return `${labels.join(" + ")} only`;
}

/** Longer tooltip copy for the badge. Null when there is nothing to show. */
export function providerRequirementTitle(capabilities?: string[] | null): string | null {
  const labels = providerCapabilityLabels(capabilities);
  if (labels.length === 0) return null;
  return `Served only by providers with: ${labels.join(", ")}`;
}
