"use client";

import { useId, useState } from "react";
import { createPortal } from "react-dom";
import {
  MarkerAnchor,
  useMarkerClusters,
  type MapRenderContext,
  type MarkerCluster,
  type MarkerDatum,
} from "@/components/stats/network-map";
import { formatGeoCount, type GeographyMode } from "./geography-data";

interface TooltipAnchor {
  x: number;
  top: number;
  bottom: number;
}

export function GeographyTooltip({
  id, cluster, mode, anchor,
}: {
  id: string;
  cluster: MarkerCluster;
  mode: GeographyMode;
  anchor: TooltipAnchor;
}) {
  const below = anchor.top < 150;
  const width = Math.min(240, window.innerWidth - 24);
  const left = Math.max(12, Math.min(window.innerWidth - width - 12, anchor.x - width / 2));
  return createPortal(
    <div
      id={id}
      role="tooltip"
      className="pointer-events-none fixed z-[100] rounded-xl border border-border-dim bg-bg-white px-4 py-3 text-text-primary shadow-xl"
      style={{ width, left, top: below ? anchor.bottom + 12 : anchor.top - 12, transform: below ? undefined : "translateY(-100%)" }}
    >
      <p className="text-[13px] font-medium leading-snug">
        {cluster.isCluster ? `${cluster.members.length} nearby locations` : cluster.members[0].label}
      </p>
      <p className="mt-1 text-sm tabular-nums text-text-secondary">{cluster.totalNodes.toLocaleString()} {mode}</p>
      {cluster.isCluster && (
        <>
          <div className="mt-3 space-y-1.5 border-t border-border-dim pt-3">
            {cluster.members.slice(0, 3).map((place) => (
              <div key={place.key} className="flex justify-between gap-4 text-xs text-text-secondary">
                <span className="truncate">{place.label}</span>
                <span className="tabular-nums">{formatGeoCount(place.nodes)}</span>
              </div>
            ))}
          </div>
          <p className="mt-3 text-xs text-text-tertiary">Select to zoom in</p>
        </>
      )}
    </div>,
    document.body,
  );
}

function GeographyMarker({
  cluster, mode, context, onExplore,
}: {
  cluster: MarkerCluster;
  mode: GeographyMode;
  context: MapRenderContext;
  onExplore: () => void;
}) {
  const id = useId();
  const [anchor, setAnchor] = useState<TooltipAnchor | null>(null);
  const size = Math.min(39, 15 + Math.log2(cluster.totalNodes + 1) * 3);
  const label = cluster.isCluster ? `${cluster.members.length} nearby locations` : cluster.members[0].label;
  function showTooltip(element: HTMLButtonElement) {
    const bounds = element.getBoundingClientRect();
    setAnchor({ x: bounds.left + bounds.width / 2, top: bounds.top, bottom: bounds.bottom });
  }
  return (
    <MarkerAnchor xPct={cluster.xPct} yPct={cluster.yPct} scale={context.scale} className="focus-within:z-50">
      <button
        type="button"
        aria-label={`${label}: ${cluster.totalNodes.toLocaleString()} ${mode}${cluster.isCluster ? ". Zoom in" : ""}`}
        aria-describedby={anchor ? id : undefined}
        onPointerDown={(event) => event.stopPropagation()}
        onDoubleClick={(event) => event.stopPropagation()}
        onMouseEnter={(event) => showTooltip(event.currentTarget)}
        onMouseLeave={() => setAnchor(null)}
        onFocus={(event) => showTooltip(event.currentTarget)}
        onBlur={() => setAnchor(null)}
        onKeyDown={(event) => { if (event.key === "Escape") setAnchor(null); }}
        onClick={(event) => {
          if (cluster.isCluster) {
            setAnchor(null);
            onExplore();
            context.zoomToPercent(cluster.xPct, cluster.yPct);
          } else {
            showTooltip(event.currentTarget);
          }
        }}
        className="relative flex h-11 min-w-11 items-center justify-center rounded-full focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand"
      >
        <span
          className="relative flex items-center justify-center rounded-full border-2 border-bg-primary bg-accent-brand px-1 text-[11px] font-medium leading-none tabular-nums text-bg-primary shadow-sm transition-transform duration-150 group-hover:scale-110 motion-reduce:transition-none"
          style={{
            minWidth: size,
            height: size,
            boxShadow: `0 0 0 ${cluster.isCluster ? 7 : 4}px color-mix(in srgb, var(--accent-brand) ${cluster.isCluster ? 11 : 7}%, transparent)`,
          }}
        >
          {cluster.totalNodes > 1 ? formatGeoCount(cluster.totalNodes) : <span className="sr-only">1</span>}
        </span>
      </button>
      {anchor && <GeographyTooltip id={id} cluster={cluster} mode={mode} anchor={anchor} />}
    </MarkerAnchor>
  );
}

export function GeographyMarkers({
  markers, mode, context, onExplore,
}: {
  markers: MarkerDatum[];
  mode: GeographyMode;
  context: MapRenderContext;
  onExplore: () => void;
}) {
  const clusters = useMarkerClusters(markers, context.scale, context, 46);
  return clusters.map((cluster) => (
    <GeographyMarker key={cluster.key} cluster={cluster} mode={mode} context={context} onExplore={onExplore} />
  ));
}
