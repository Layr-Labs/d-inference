// Pure display formatters for the earnings page. No React, no fetch.

import { microToUsd } from "@/lib/format/currency";

/** Per-job amounts are sub-cent; always show full 6-decimal precision. */
export function formatMicroExact(micro: number): string {
  return `$${microToUsd(micro).toFixed(6)}`;
}

/** Headline dollars: "$1,284.36". */
export function formatMicroDollars(micro: number): string {
  return `$${microToUsd(micro).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

/**
 * Average-per-job display. Consistent precision at every magnitude
 * (the old page mixed toFixed(6) with a literal "0.00").
 */
export function formatAvgPerJob(totalMicro: number, jobs: number): string {
  if (jobs <= 0) return "$0.00";
  const avg = microToUsd(totalMicro) / jobs;
  if (avg === 0) return "$0.00";
  if (avg < 1) return `$${avg.toFixed(4)}`;
  return `$${avg.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

/** Token counts with thousands separators. */
export function formatTokens(n: number): string {
  return n.toLocaleString("en-US");
}

/**
 * Short model label ("org/name" -> "name"), but keep the full id when two
 * different orgs ship the same short name so rows stay distinguishable.
 */
export function modelLabel(model: string, allModels: string[]): string {
  const short = model.split("/").pop() || model;
  const collision = allModels.some(
    (m) => m !== model && (m.split("/").pop() || m) === short,
  );
  return collision ? model : short;
}

/** Row timestamp: "May 30, 2025, 10:24 AM". */
export function formatRowTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

/** Short axis label for a YYYY-MM-DD day bucket: "May 30". */
export function formatDayLabel(day: string): string {
  const d = new Date(`${day}T00:00:00`);
  if (Number.isNaN(d.getTime())) return day;
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}
