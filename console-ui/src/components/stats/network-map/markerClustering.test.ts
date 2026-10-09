import { describe, expect, it } from "vitest";
import {
  DEFAULT_CLUSTER_THRESHOLD_PX,
  clusterMarkers,
  type ClusterViewport,
  type MarkerDatum,
} from "./markerClustering";

const VIEWPORT: ClusterViewport = { width: 1000, height: 500 };

function marker(key: string, xPct: number, yPct: number, nodes: number): MarkerDatum {
  return { key, xPct, yPct, nodes, label: key, detail: `${nodes} nodes` };
}

describe("clusterMarkers", () => {
  it("merges overlapping markers into one cluster with a weighted centroid and summed count", () => {
    // Container px: A=(400,250) B=(600,250), 200px apart → merge with a wide threshold.
    const a = marker("a", 40, 50, 3);
    const b = marker("b", 60, 50, 1);
    const [cluster, ...rest] = clusterMarkers([a, b], 1, VIEWPORT, 400);

    expect(rest).toHaveLength(0);
    expect(cluster.isCluster).toBe(true);
    expect(cluster.totalNodes).toBe(4);
    expect(cluster.members).toHaveLength(2);
    // Weighted centroid: (40*3 + 60*1) / 4 = 45.
    expect(cluster.xPct).toBeCloseTo(45, 6);
    expect(cluster.yPct).toBeCloseTo(50, 6);
    // Dominant member (more nodes) leads and defines the key.
    expect(cluster.key).toBe("a");
    expect(cluster.members[0].key).toBe("a");
  });

  it("keeps well-separated markers as independent singletons", () => {
    const a = marker("a", 10, 10, 5);
    const b = marker("b", 90, 90, 5);
    const clusters = clusterMarkers([a, b], 1, VIEWPORT, DEFAULT_CLUSTER_THRESHOLD_PX);

    expect(clusters).toHaveLength(2);
    for (const cluster of clusters) {
      expect(cluster.isCluster).toBe(false);
      expect(cluster.members).toHaveLength(1);
    }
  });

  it("declusters as scale increases (higher scale → more, smaller clusters)", () => {
    // A tight 2x2 block: container px (500,250),(510,250),(500,255),(510,255).
    const block = [
      marker("a", 50, 50, 4),
      marker("b", 51, 50, 3),
      marker("c", 50, 51, 2),
      marker("d", 51, 51, 1),
    ];

    const atOne = clusterMarkers(block, 1, VIEWPORT, DEFAULT_CLUSTER_THRESHOLD_PX);
    const atEight = clusterMarkers(block, 8, VIEWPORT, DEFAULT_CLUSTER_THRESHOLD_PX);

    expect(atOne).toHaveLength(1);
    expect(atOne[0].isCluster).toBe(true);
    expect(atOne[0].totalNodes).toBe(10);

    expect(atEight.length).toBeGreaterThan(atOne.length);
    expect(atEight).toHaveLength(4);
    for (const cluster of atEight) {
      expect(cluster.isCluster).toBe(false);
    }
  });

  it("marks a lone marker as a non-cluster at its own position", () => {
    const [only] = clusterMarkers([marker("solo", 25, 75, 7)], 1, VIEWPORT);
    expect(only.isCluster).toBe(false);
    expect(only.totalNodes).toBe(7);
    expect(only.xPct).toBe(25);
    expect(only.yPct).toBe(75);
  });

  it("treats a degenerate (unmeasured) viewport as all singletons", () => {
    const clusters = clusterMarkers(
      [marker("a", 50, 50, 1), marker("b", 50, 50, 1)],
      1,
      { width: 0, height: 0 },
    );
    expect(clusters).toHaveLength(2);
    expect(clusters.every((c) => !c.isCluster)).toBe(true);
  });

  it("is deterministic across calls and input order", () => {
    const items = [
      marker("a", 50, 50, 4),
      marker("b", 51, 50, 3),
      marker("c", 50, 51, 2),
      marker("z", 80, 20, 9),
    ];
    const first = clusterMarkers(items, 1.5, VIEWPORT);
    const second = clusterMarkers([...items].reverse(), 1.5, VIEWPORT);
    expect(first).toEqual(second);
  });
});
