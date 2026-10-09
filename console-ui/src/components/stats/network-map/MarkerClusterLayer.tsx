"use client";

import { ClusterMarker } from "./ClusterMarker";
import { NodeMarker } from "./NodeMarker";
import { useMarkerClusters } from "./useMarkerClusters";
import type { MarkerDatum } from "./markerClustering";

/** Flip tooltips below the marker when it sits near the top edge. */
const TOOLTIP_FLIP_THRESHOLD = 32;

interface MarkerClusterLayerProps {
  markers: MarkerDatum[];
  /** Current zoom scale (drives both clustering and per-marker counter-scaling). */
  scale: number;
  /** Container size in pixels (for screen-space clustering). */
  width: number;
  height: number;
  /** Zoom toward a container-percentage point — used for cluster drill-in. */
  onZoomToPercent: (xPct: number, yPct: number) => void;
  thresholdPx?: number;
}

/**
 * Renders provider markers with zoom-aware clustering: overlapping cities merge
 * into a single {@link ClusterMarker} at the current zoom and split back into
 * individual {@link NodeMarker}s as the user zooms in (clusters dissolve because
 * on-screen gaps grow with scale).
 */
export function MarkerClusterLayer({
  markers,
  scale,
  width,
  height,
  onZoomToPercent,
  thresholdPx,
}: MarkerClusterLayerProps) {
  const clusters = useMarkerClusters(markers, scale, { width, height }, thresholdPx);

  return (
    <>
      {clusters.map((cluster) => {
        const tooltipBelow = cluster.yPct < TOOLTIP_FLIP_THRESHOLD;
        if (!cluster.isCluster) {
          const member = cluster.members[0];
          return (
            <NodeMarker
              key={cluster.key}
              xPct={cluster.xPct}
              yPct={cluster.yPct}
              count={member.nodes}
              scale={scale}
              label={member.label}
              detail={member.detail}
              tooltipBelow={tooltipBelow}
            />
          );
        }
        return (
          <ClusterMarker
            key={cluster.key}
            xPct={cluster.xPct}
            yPct={cluster.yPct}
            totalNodes={cluster.totalNodes}
            members={cluster.members}
            scale={scale}
            tooltipBelow={tooltipBelow}
            onZoomIn={() => onZoomToPercent(cluster.xPct, cluster.yPct)}
          />
        );
      })}
    </>
  );
}
