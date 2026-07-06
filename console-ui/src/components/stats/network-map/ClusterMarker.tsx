"use client";

import { MarkerAnchor } from "./MarkerAnchor";
import type { MarkerDatum } from "./markerClustering";

const MAX_TOOLTIP_MEMBERS = 4;

interface ClusterMarkerProps {
  /** Weighted-centroid position as percentages of the map container. */
  xPct: number;
  yPct: number;
  /** Summed node count across all members. */
  totalNodes: number;
  /** Members, sorted by node count desc (for the tooltip list). */
  members: MarkerDatum[];
  /** Current zoom scale; the marker counter-scales by 1/scale. */
  scale: number;
  tooltipBelow: boolean;
  /** Drill in toward the cluster centroid. */
  onZoomIn: () => void;
}

/** Keep cluster clicks from also triggering the viewport's drag/double-click zoom. */
function stopPropagation(event: { stopPropagation: () => void }) {
  event.stopPropagation();
}

/**
 * Aggregate marker for multiple overlapping cities at the current zoom. Reads as
 * "many" via concentric stacked rings behind a brand core that shows the summed
 * node count, stays constant pixel-size (counter-scaled), and on click zooms the
 * map toward its centroid to break the cluster apart. Hover reveals the top
 * member cities; the whole marker is a keyboard-focusable button.
 */
export function ClusterMarker({
  xPct,
  yPct,
  totalNodes,
  members,
  scale,
  tooltipBelow,
  onZoomIn,
}: ClusterMarkerProps) {
  const core = Math.min(40, 22 + Math.sqrt(totalNodes) * 2.4);
  const cityCount = members.length;
  const visibleMembers = members.slice(0, MAX_TOOLTIP_MEMBERS);
  const remaining = cityCount - visibleMembers.length;

  return (
    <MarkerAnchor xPct={xPct} yPct={yPct} scale={scale}>
      <button
        type="button"
        aria-label={`Zoom into ${cityCount} clustered locations totaling ${totalNodes} nodes`}
        onClick={onZoomIn}
        onPointerDown={stopPropagation}
        onDoubleClick={stopPropagation}
        className="relative block cursor-pointer appearance-none rounded-full border-0 bg-transparent p-0 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent-brand"
      >
        <span
          aria-hidden="true"
          className="absolute left-1/2 top-1/2 -z-10 -translate-x-1/2 -translate-y-1/2 rounded-full transition-opacity duration-200 group-hover:opacity-100"
          style={{
            width: `${core * 2}px`,
            height: `${core * 2}px`,
            background: "color-mix(in srgb, var(--accent-brand) 10%, transparent)",
          }}
        />
        <span
          aria-hidden="true"
          className="absolute left-1/2 top-1/2 -z-10 -translate-x-1/2 -translate-y-1/2 rounded-full border"
          style={{
            width: `${core * 1.5}px`,
            height: `${core * 1.5}px`,
            borderColor: "color-mix(in srgb, var(--accent-brand) 32%, transparent)",
          }}
        />
        <span
          aria-hidden="true"
          className="absolute left-1/2 top-1/2 -z-10 -translate-x-1/2 -translate-y-1/2 rounded-full border"
          style={{
            width: `${core * 1.24}px`,
            height: `${core * 1.24}px`,
            borderColor: "color-mix(in srgb, var(--accent-brand) 48%, transparent)",
          }}
        />
        <span
          className="flex items-center justify-center rounded-full border-2 border-bg-primary font-mono font-bold leading-none text-white transition-transform duration-200 group-hover:scale-110"
          style={{
            width: `${core}px`,
            height: `${core}px`,
            fontSize: `${Math.max(9, core * 0.4)}px`,
            background: "var(--accent-brand)",
          }}
        >
          {totalNodes}
        </span>
      </button>
      <div
        className={`pointer-events-none absolute left-1/2 z-50 hidden -translate-x-1/2 group-hover:block ${
          tooltipBelow ? "top-full mt-2.5" : "bottom-full mb-2.5"
        }`}
      >
        <div className="min-w-[200px] rounded-lg bg-text-primary px-3 py-2 text-bg-primary shadow-lg">
          <p className="text-xs font-semibold">
            {totalNodes} nodes · {cityCount} cities
          </p>
          <div className="mt-1.5 space-y-0.5">
            {visibleMembers.map((member) => (
              <p key={member.key} className="flex justify-between gap-4 text-[11px] font-mono opacity-80">
                <span className="truncate">{member.label}</span>
                <span className="shrink-0">{member.nodes}</span>
              </p>
            ))}
            {remaining > 0 && <p className="text-[11px] font-mono opacity-60">+{remaining} more</p>}
          </div>
          <p className="mt-1.5 text-[10px] font-mono uppercase tracking-wide opacity-55">click to zoom in</p>
        </div>
      </div>
    </MarkerAnchor>
  );
}
