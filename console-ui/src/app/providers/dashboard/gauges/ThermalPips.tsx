// Thermal state as a 4-segment pill track: nominal → fair → serious → critical.
// Segments up to and including the current state light up; color escalates
// green → amber → amber → red. The textual state always accompanies it.

import type { MySystemMetrics } from "../../types";

type Thermal = MySystemMetrics["thermal_state"];

const ORDER: Thermal[] = ["nominal", "fair", "serious", "critical"];

// Lit color per index (0..3). Index 2 (serious) reuses amber but the label
// disambiguates; index 3 (critical) is red.
const LIT = ["bg-accent-green", "bg-accent-amber", "bg-accent-amber", "bg-accent-red"];

export function ThermalPips({ state }: { state?: Thermal }) {
  // Unknown/missing thermal strings fall back to nominal (index 0).
  const found = ORDER.indexOf((state as Thermal) ?? "nominal");
  const active = found < 0 ? 0 : found;
  return (
    <div
      className="flex items-center gap-0.5"
      role="meter"
      aria-valuenow={active + 1}
      aria-valuemin={1}
      aria-valuemax={4}
      aria-label={`Thermal: ${state ?? "nominal"}`}
    >
      {ORDER.map((_, i) => (
        <span
          key={i}
          className={`h-2 flex-1 rounded-sm transition-colors duration-500 ${
            i <= active ? LIT[active] : "bg-bg-tertiary"
          }`}
        />
      ))}
    </div>
  );
}
