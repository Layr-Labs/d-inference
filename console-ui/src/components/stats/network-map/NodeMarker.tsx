"use client";

import { MarkerAnchor } from "./MarkerAnchor";

interface NodeMarkerProps {
  /** Anchor position as percentages of the map container. */
  xPct: number;
  yPct: number;
  /** Number of provider nodes at this location. */
  count: number;
  /** Current map zoom scale; the marker counter-scales by 1/scale to stay constant size. */
  scale: number;
  /** Place label + detail line for the hover tooltip. */
  label: string;
  detail: string;
  /** Flip the tooltip below the marker when it sits near the top edge. */
  tooltipBelow: boolean;
}

/**
 * Premium single-location provider marker: a crisp brand pin with a count-scaled
 * halo (sqrt, so busier cities read bigger without becoming blobs). A city with
 * more than one node shows the count inside the pin; a singleton is a clean dot.
 * Hover (via the `group`) lifts the pin and reveals the tooltip.
 */
export function NodeMarker({ xPct, yPct, count, scale, label, detail, tooltipBelow }: NodeMarkerProps) {
  const isMultiNode = count > 1;
  const core = isMultiNode ? Math.min(30, 16 + Math.sqrt(count) * 2.6) : 11;
  const haloRadius = core / 2 + Math.min(17, 5 + Math.sqrt(count) * 3.2);

  return (
    <MarkerAnchor xPct={xPct} yPct={yPct} scale={scale}>
      <span
        aria-hidden="true"
        className="pointer-events-none absolute left-1/2 top-1/2 -z-10 -translate-x-1/2 -translate-y-1/2 rounded-full transition-opacity duration-200 group-hover:opacity-100"
        style={{
          width: `${haloRadius * 2}px`,
          height: `${haloRadius * 2}px`,
          opacity: 0.7,
          background:
            "radial-gradient(circle, color-mix(in srgb, var(--accent-brand) 26%, transparent), transparent 70%)",
        }}
      />
      <div
        className="relative flex items-center justify-center rounded-full border-2 border-bg-primary font-mono font-semibold leading-none text-white shadow-sm transition-transform duration-200 group-hover:scale-110"
        style={{
          width: `${core}px`,
          height: `${core}px`,
          fontSize: `${Math.max(8, core * 0.42)}px`,
          background:
            "radial-gradient(circle at 32% 26%, color-mix(in srgb, white 34%, var(--accent-brand)), var(--accent-brand) 68%)",
          boxShadow:
            "0 1px 4px color-mix(in srgb, var(--accent-brand) 42%, transparent), 0 0 0 1px color-mix(in srgb, var(--accent-brand) 28%, transparent)",
        }}
      >
        {isMultiNode ? count : null}
      </div>
      <div
        className={`pointer-events-none absolute left-1/2 z-50 hidden -translate-x-1/2 group-hover:block ${
          tooltipBelow ? "top-full mt-2.5" : "bottom-full mb-2.5"
        }`}
      >
        <div className="min-w-[190px] rounded-lg bg-text-primary px-3 py-2 text-bg-primary shadow-lg">
          <p className="text-xs font-semibold">{label}</p>
          <p className="text-[11px] font-mono opacity-80 mt-1">{detail}</p>
        </div>
      </div>
    </MarkerAnchor>
  );
}
