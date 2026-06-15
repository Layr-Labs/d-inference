// Auto-scales a wattage to W / kW / MW / GW with sensible precision.
// 950 -> "950 W"; 20855 -> "20.9 kW"; 187000 -> "187 kW"; 1.4e6 -> "1.4 MW"; 2.1e9 -> "2.1 GW"
//
// Pure (no React). Rules:
//   undefined / null / NaN / <= 0 -> "—"
//   < 1000 W      -> "{Math.round} W"
//   < 1e6         -> kW (one decimal if < 100 kW, else integer)
//   < 1e9         -> MW (one decimal if < 100, else integer)
//   else          -> GW (one decimal if < 100, else integer)
// Trailing ".0" is stripped.

function trimZero(value: string): string {
  return value.endsWith(".0") ? value.slice(0, -2) : value;
}

function scale(value: number, unit: string): string {
  // One decimal under 100 of the unit, integer at/above 100.
  const formatted = value < 100 ? value.toFixed(1) : Math.round(value).toString();
  return `${trimZero(formatted)} ${unit}`;
}

export function formatPower(watts: number | undefined | null): string {
  if (watts === undefined || watts === null || !Number.isFinite(watts) || watts <= 0) {
    return "—";
  }

  if (watts < 1_000) {
    return `${Math.round(watts)} W`;
  }
  if (watts < 1_000_000) {
    return scale(watts / 1_000, "kW");
  }
  if (watts < 1_000_000_000) {
    return scale(watts / 1_000_000, "MW");
  }
  return scale(watts / 1_000_000_000, "GW");
}
