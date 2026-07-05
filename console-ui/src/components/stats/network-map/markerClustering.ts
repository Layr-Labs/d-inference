/**
 * Pure, DOM-free zoom-aware marker clustering.
 *
 * Markers are positioned by container percentage and rendered at constant pixel
 * size (the map counter-scales them by 1/scale). So the *on-screen* gap between
 * two markers equals their container-pixel gap times the current zoom `scale`.
 * Clustering therefore happens in on-screen pixel space: two markers merge when
 * that on-screen gap is below `thresholdPx`. Increasing `scale` widens real gaps,
 * so clusters dissolve automatically as the user zooms in.
 *
 * Greedy, deterministic: markers are processed highest-node-count first; each
 * unclaimed marker seeds a cluster and absorbs every unclaimed marker within the
 * threshold; the cluster sits at the node-weighted centroid and reports the summed
 * node count.
 */

export interface MarkerDatum {
  /** Stable unique id (used for ordering, claiming, and React keys). */
  key: string;
  /** Position as a percentage (0..100) of the map container. */
  xPct: number;
  yPct: number;
  /** Node count at this location — the clustering weight and displayed value. */
  nodes: number;
  /** Tooltip label + detail line for single-marker rendering. */
  label: string;
  detail: string;
}

export interface MarkerCluster {
  /** Stable key (the dominant member's key). */
  key: string;
  /** Node-count-weighted centroid (percent of container). */
  xPct: number;
  yPct: number;
  /** Sum of member node counts. */
  totalNodes: number;
  /** Members, sorted by node count desc; length 1 for a singleton. */
  members: MarkerDatum[];
  /** True when more than one marker merged. */
  isCluster: boolean;
}

export interface ClusterViewport {
  width: number;
  height: number;
}

/** On-screen merge distance (~marker diameter + padding). Tunable. */
export const DEFAULT_CLUSTER_THRESHOLD_PX = 40;

function isPositive(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

function byNodesDesc(a: MarkerDatum, b: MarkerDatum): number {
  if (b.nodes !== a.nodes) return b.nodes - a.nodes;
  if (a.key < b.key) return -1;
  if (a.key > b.key) return 1;
  return 0;
}

/** Straight-line distance between two markers in container pixels. */
function containerDistance(a: MarkerDatum, b: MarkerDatum, viewport: ClusterViewport): number {
  const dx = ((a.xPct - b.xPct) / 100) * viewport.width;
  const dy = ((a.yPct - b.yPct) / 100) * viewport.height;
  return Math.hypot(dx, dy);
}

function buildCluster(members: MarkerDatum[]): MarkerCluster {
  const sorted = [...members].sort(byNodesDesc);
  let weightedX = 0;
  let weightedY = 0;
  let weight = 0;
  let plainX = 0;
  let plainY = 0;
  for (const member of sorted) {
    weightedX += member.xPct * member.nodes;
    weightedY += member.yPct * member.nodes;
    weight += member.nodes;
    plainX += member.xPct;
    plainY += member.yPct;
  }
  const primary = sorted[0];
  const useWeighted = weight > 0;
  return {
    key: primary.key,
    xPct: useWeighted ? weightedX / weight : plainX / sorted.length,
    yPct: useWeighted ? weightedY / weight : plainY / sorted.length,
    totalNodes: weight,
    members: sorted,
    isCluster: sorted.length > 1,
  };
}

/** Absorb every still-unclaimed marker within `maxDistance` of the seed. */
function absorbNeighbors(
  seed: MarkerDatum,
  ordered: MarkerDatum[],
  claimed: Set<string>,
  viewport: ClusterViewport,
  maxDistance: number,
): MarkerDatum[] {
  const members = [seed];
  for (const candidate of ordered) {
    if (claimed.has(candidate.key)) continue;
    if (containerDistance(seed, candidate, viewport) < maxDistance) {
      claimed.add(candidate.key);
      members.push(candidate);
    }
  }
  return members;
}

/**
 * Cluster markers for the current zoom `scale`. Returns clusters ordered by node
 * count desc; singletons have `isCluster: false`. Output is fully deterministic.
 */
export function clusterMarkers(
  markers: MarkerDatum[],
  scale: number,
  viewport: ClusterViewport,
  thresholdPx: number = DEFAULT_CLUSTER_THRESHOLD_PX,
): MarkerCluster[] {
  const ordered = [...markers].sort(byNodesDesc);

  // Without on-screen geometry (pre-measure / SSR) every marker stands alone.
  if (!isPositive(viewport.width) || !isPositive(viewport.height) || !isPositive(scale)) {
    return ordered.map((marker) => buildCluster([marker]));
  }

  const maxDistance = thresholdPx / scale;
  const claimed = new Set<string>();
  const clusters: MarkerCluster[] = [];
  for (const seed of ordered) {
    if (claimed.has(seed.key)) continue;
    claimed.add(seed.key);
    clusters.push(buildCluster(absorbNeighbors(seed, ordered, claimed, viewport, maxDistance)));
  }
  return clusters;
}
