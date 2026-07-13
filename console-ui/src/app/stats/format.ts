const COMPACT_UNITS = [
  { threshold: 1_000_000_000_000, suffix: "T" },
  { threshold: 1_000_000_000, suffix: "B" },
  { threshold: 1_000_000, suffix: "M" },
  { threshold: 1_000, suffix: "K" },
];

function trimFixedZeros(value: string): string {
  let trimmed = value;
  while (trimmed.endsWith("0")) trimmed = trimmed.slice(0, -1);
  return trimmed.endsWith(".") ? trimmed.slice(0, -1) : trimmed;
}

export function formatCompactNumber(value: number): string {
  if (!Number.isFinite(value)) return "—";

  const magnitude = Math.abs(value);
  const unit = COMPACT_UNITS.find((candidate) => magnitude >= candidate.threshold);
  if (!unit) return Math.round(value).toLocaleString();

  const scaled = value / unit.threshold;
  const digits = Math.abs(scaled) < 100 ? 2 : 0;
  const formatted = scaled.toFixed(digits);
  return `${digits > 0 ? trimFixedZeros(formatted) : formatted}${unit.suffix}`;
}

export function formatBandwidth(gigabytesPerSecond: number): string {
  if (!Number.isFinite(gigabytesPerSecond)) return "—";
  if (Math.abs(gigabytesPerSecond) >= 1_000) {
    const terabytesPerSecond = gigabytesPerSecond / 1_000;
    const digits = Math.abs(terabytesPerSecond) < 100 ? 1 : 0;
    return `${terabytesPerSecond.toFixed(digits).replace(/\.0$/, "")} TB/s`;
  }
  return `${Math.round(gigabytesPerSecond).toLocaleString()} GB/s`;
}
