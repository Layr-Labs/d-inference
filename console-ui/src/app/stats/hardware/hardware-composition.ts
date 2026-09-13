import type { PlatformStats } from "../platform-types";
import type { ProviderStats } from "../provider-fleet";

export interface HardwareFamily {
  key: string;
  label: string;
  providers: number;
  memoryGB: number;
  memoryReportedProviders: number;
}

export interface HardwareCompositionData {
  families: HardwareFamily[];
  chartFamilies: HardwareFamily[];
  providers: number;
  memoryGB: number;
  memoryUnreportedProviders: number;
  hardwareAttestedProviders: number;
  attestationUnreportedProviders: number;
  otherAttestationProviders: number;
  coordinatorProviders: number | null;
  coordinatorMemoryGB: number | null;
}

const UNKNOWN_FAMILY = "unknown";
const MAX_NAMED_FAMILIES = 5;
const validNonnegative = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0;

function chipFamily(provider: ProviderStats): { key: string; label: string } {
  const reported = (provider.chip_family || "").trim();
  // Fall back only to an explicitly reported Apple chip name, never to its RAM,
  // speed, or model inventory. Unknown metadata remains an explicit group.
  const generation = /\bM\d+\b/i.exec(reported || provider.chip || "")?.[0].toUpperCase();
  if (generation) return { key: generation.toLowerCase(), label: generation };
  if (reported && !/^(unknown|unspecified|n\/a)$/i.test(reported)) {
    return { key: `reported:${reported.toLowerCase()}`, label: reported };
  }
  return { key: UNKNOWN_FAMILY, label: "Unreported" };
}

function chartFamilies(families: HardwareFamily[]): HardwareFamily[] {
  const known = families.filter((family) => family.key !== UNKNOWN_FAMILY);
  const visible = known.slice(0, MAX_NAMED_FAMILIES);
  const remaining = known.slice(MAX_NAMED_FAMILIES);
  if (remaining.length > 0) {
    visible.push(remaining.reduce<HardwareFamily>((other, family) => ({
      ...other,
      providers: other.providers + family.providers,
      memoryGB: other.memoryGB + family.memoryGB,
      memoryReportedProviders: other.memoryReportedProviders + family.memoryReportedProviders,
    }), { key: "other", label: "Other silicon", providers: 0, memoryGB: 0, memoryReportedProviders: 0 }));
  }
  const unknown = families.find((family) => family.key === UNKNOWN_FAMILY);
  if (unknown) visible.push(unknown);
  return visible;
}

export function buildHardwareComposition(stats: PlatformStats): HardwareCompositionData {
  const families = new Map<string, HardwareFamily>();
  let memoryGB = 0;
  let memoryUnreportedProviders = 0;
  let hardwareAttestedProviders = 0;
  let attestationUnreportedProviders = 0;
  for (const provider of stats.providers) {
    const identity = chipFamily(provider);
    const family = families.get(identity.key) ?? { ...identity, providers: 0, memoryGB: 0, memoryReportedProviders: 0 };
    family.providers += 1;
    if (validNonnegative(provider.memory_gb) && provider.memory_gb > 0) {
      family.memoryGB += provider.memory_gb;
      family.memoryReportedProviders += 1;
      memoryGB += provider.memory_gb;
    } else {
      memoryUnreportedProviders += 1;
    }
    if (provider.trust_level === "hardware" && provider.attested === true) {
      hardwareAttestedProviders += 1;
    } else if (typeof provider.attested !== "boolean" || !provider.trust_level) {
      attestationUnreportedProviders += 1;
    }
    families.set(identity.key, family);
  }
  const ordered = [...families.values()].sort((a, b) => b.providers - a.providers || a.label.localeCompare(b.label));
  return {
    families: ordered,
    chartFamilies: chartFamilies(ordered),
    providers: stats.providers.length,
    memoryGB,
    memoryUnreportedProviders,
    hardwareAttestedProviders,
    attestationUnreportedProviders,
    otherAttestationProviders: stats.providers.length - hardwareAttestedProviders - attestationUnreportedProviders,
    coordinatorProviders: validNonnegative(stats.active_providers) ? stats.active_providers : null,
    coordinatorMemoryGB: validNonnegative(stats.total_memory_gb) ? stats.total_memory_gb : null,
  };
}

export function hardwareShare(value: number, total: number): string {
  if (!total) return "—";
  const percent = value / total * 100;
  if (percent > 0 && percent < 1) return "<1%";
  return `${Math.round(percent)}%`;
}

export function formatHardwareMemory(memoryGB: number): string {
  if (memoryGB >= 1_000) return `${(memoryGB / 1_000).toLocaleString(undefined, { maximumFractionDigits: 2 })} TB`;
  return `${memoryGB.toLocaleString(undefined, { maximumFractionDigits: 1 })} GB`;
}
