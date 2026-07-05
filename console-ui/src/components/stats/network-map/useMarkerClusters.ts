"use client";

import { useMemo } from "react";
import { clusterMarkers, type ClusterViewport, type MarkerCluster, type MarkerDatum } from "./markerClustering";

/**
 * Memoized wrapper around {@link clusterMarkers}. Recomputes only when the marker
 * set, zoom `scale`, container size, or threshold changes — so panning is free
 * while zooming re-clusters (declustering) as the on-screen gaps grow.
 */
export function useMarkerClusters(
  markers: MarkerDatum[],
  scale: number,
  viewport: ClusterViewport,
  thresholdPx?: number,
): MarkerCluster[] {
  const { width, height } = viewport;
  return useMemo(
    () => clusterMarkers(markers, scale, { width, height }, thresholdPx),
    [markers, scale, width, height, thresholdPx],
  );
}
