// Formatting helpers for the provider dashboard. These now live in the shared
// lib/format module (single source — proposal F5); re-exported here so the
// dashboard's many `./format` import sites are unchanged. `formatUSD` is the
// dashboard's name for the micro-USD formatter.
export {
  formatUsdMicro as formatUSD,
  formatRelative,
  formatNumber,
  abbreviateNumber,
  maskSerial,
  shortModelName,
  pct,
  clampPct,
  formatTps,
  humanizeUptime,
} from "@/lib/format";
