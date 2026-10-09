"use client";

import type { ReactNode } from "react";

interface MarkerAnchorProps {
  /** Anchor position as percentages of the map container. */
  xPct: number;
  yPct: number;
  /** Current zoom scale; the visual layer counter-scales by 1/scale to stay constant size. */
  scale: number;
  /** Extra classes for the outer `group` element. */
  className?: string;
  children: ReactNode;
}

/**
 * Shared positioning shell for map markers: places a `group` at the anchor,
 * centers it, and counter-scales its contents by `1/scale` so markers keep a
 * constant on-screen size while their spacing grows with zoom. Both
 * {@link NodeMarker} and the cluster marker build on this so the counter-scale
 * invariant lives in exactly one place.
 */
export function MarkerAnchor({ xPct, yPct, scale, className, children }: MarkerAnchorProps) {
  const outerClasses = ["group absolute z-20 -translate-x-1/2 -translate-y-1/2 hover:z-50", className]
    .filter(Boolean)
    .join(" ");
  return (
    <div
      className={outerClasses}
      style={{ left: `${xPct}%`, top: `${yPct}%` }}
    >
      <div className="relative" style={{ transform: `scale(${1 / scale})`, transformOrigin: "center" }}>
        {children}
      </div>
    </div>
  );
}
